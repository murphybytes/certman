// Package repository provides access to the certman Azure SQL database.
package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	_ "github.com/microsoft/go-mssqldb"
	"github.com/microsoft/go-mssqldb/azuread"
)

const connectTimeout = 30 * time.Second

// Store is the set of operations on the certman database. Certdb implements
// it; depend on Store where a fake is useful in tests.
type Store interface {
	RegisterDomain(ctx context.Context, domainName string, emails []string) (int32, error)
	UnregisterDomain(ctx context.Context, id int32) error
	GetCertificateInfo(ctx context.Context, id int32) (*Certificate, error)
	GetDomainsWithPendingCertificates(ctx context.Context) ([]Certificate, error)
	SetState(ctx context.Context, id int32, state CertificateState) error
	GetCertificateNotifications(ctx context.Context, certID int32) ([]Notification, error)
	AddCertificateNotification(ctx context.Context, certID int32, email string) (int32, error)
	DeleteCertificateNotification(ctx context.Context, notificationID int32) error
	Close() error
}

// Certdb is a handle to the certman database. It is safe for concurrent use.
type Certdb struct {
	db *sqlx.DB
}

var _ Store = (*Certdb)(nil)

// New opens a connection to the Azure SQL database described by connString
// and verifies it is reachable. The server uses Entra-only authentication, so
// connString must set fedauth, for example:
//
//	sqlserver://<server>.database.windows.net?database=certdb&fedauth=ActiveDirectoryDefault
//
// ActiveDirectoryDefault uses the Azure CLI login locally and the managed
// identity when running in Azure.
//
// ctx bounds the connection check, which also gives up after connectTimeout.
func New(ctx context.Context, connString string) (*Certdb, error) {
	db, err := sqlx.Open(azuread.DriverName, connString)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("connecting to database: %w", err)
	}

	return &Certdb{db: db}, nil
}

// RegisterDomain adds a certificate record for domainName in StateNew, along
// with a notification for each address in emails, and returns the new
// certificate's ID. The certificate and its notifications are inserted in one
// transaction, so nothing is saved if any insert fails, including when the
// domain is already registered.
func (c *Certdb) RegisterDomain(ctx context.Context, domainName string, emails []string) (int32, error) {
	tx, err := c.db.BeginTxx(ctx, &sql.TxOptions{})
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	query := `
			INSERT INTO  System.tbl_cert (domain)
			OUTPUT INSERTED.id 
			VALUES (@domain);
	`
	var insertedID int32

	err = tx.QueryRowxContext(ctx, query, sql.Named("domain", domainName)).Scan(&insertedID)
	if err != nil {
		return 0, err
	}

	// Insert each email as a parameter, never as SQL text, so addresses can't
	// inject SQL.
	for _, email := range emails {
		_, err = tx.ExecContext(
			ctx,
			"INSERT INTO System.tbl_notification (cert_id, email) VALUES (@certID, @email)",
			sql.Named("certID", insertedID),
			sql.Named("email", email),
		)
		if err != nil {
			return 0, fmt.Errorf("adding notification for %q: %w", email, err)
		}
	}

	err = tx.Commit()
	return insertedID, err
}

// GetCertificateNotifications returns the notifications for certificate
// certID. It returns an empty result, not an error, if the certificate has none
// or doesn't exist.
func (c *Certdb) GetCertificateNotifications(ctx context.Context, certID int32) ([]Notification, error) {
	query := `
		SELECT id, email 
		FROM System.tbl_notification
		WHERE cert_id = @certID 
	`
	var results []Notification
	err := c.db.SelectContext(ctx, &results, query, sql.Named("certID", certID))
	return results, err
}

// DeleteCertificateNotification deletes notification notificationID. It
// returns nil if no notification has that ID.
func (c *Certdb) DeleteCertificateNotification(ctx context.Context, notificationID int32) error {
	_, err := c.db.ExecContext(
		ctx,
		"DELETE FROM System.tbl_notification WHERE id = @id",
		sql.Named("id", notificationID),
	)
	return err
}

// AddCertificateNotification adds email to the notifications for certificate
// certID and returns the new notification's ID. It fails if the certificate
// doesn't exist or already has a notification for email.
func (c *Certdb) AddCertificateNotification(ctx context.Context, certID int32, email string) (int32, error) {
	query := `
		INSERT INTO System.tbl_notification (cert_id, email)
		OUTPUT INSERTED.id
		VALUES (@certID, @email)
	`
	var insertedID int32

	err := c.db.QueryRowxContext(
		ctx,
		query,
		sql.Named("certID", certID), sql.Named("email", email),
	).Scan(&insertedID)
	return insertedID, err
}

// GetDomainsWithPendingCertificates returns the certificates that still need
// work: those in StateNew, StateExpiring, StateOrdered or StateValidated.
func (c *Certdb) GetDomainsWithPendingCertificates(ctx context.Context) ([]Certificate, error) {
	query := `
		SELECT id, domain, state, created, modified 
		FROM System.tbl_cert
		WHERE state IN (@p1, @p2, @p3, @p4)
	`
	var certs []Certificate
	err := c.db.SelectContext(
		ctx,
		&certs,
		query,
		StateNew, StateExpiring, StateOrdered, StateValidated,
	)

	return certs, err
}

// SetState changes the state of certificate id and updates its modified time.
// It returns an error wrapping sql.ErrNoRows if no certificate has that id.
func (c *Certdb) SetState(ctx context.Context, id int32, state CertificateState) error {
	query := `
		UPDATE System.tbl_cert
		SET state = @state, modified = SYSUTCDATETIME()
		WHERE id = @id
	`
	result, err := c.db.ExecContext(
		ctx,
		query,
		sql.Named("state", state),
		sql.Named("id", id),
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return fmt.Errorf("setting state of certificate %d: %w", id, sql.ErrNoRows)
	}
	return nil
}

// GetCertificateInfo returns certificate id. It returns sql.ErrNoRows if no
// certificate has that ID.
func (c *Certdb) GetCertificateInfo(ctx context.Context, id int32) (*Certificate, error) {
	var certInfo Certificate
	err := c.db.GetContext(ctx,
		&certInfo,
		"SELECT id, domain, state, created, modified FROM System.tbl_cert WHERE id = @id",
		sql.Named("id", id),
	)
	return &certInfo, err
}

// UnregisterDomain deletes certificate id and, through the database's cascading
// delete, its notifications. It returns nil if no certificate has that ID.
func (c *Certdb) UnregisterDomain(ctx context.Context, id int32) error {
	_, err := c.db.ExecContext(ctx,
		"DELETE FROM System.tbl_cert WHERE id = @id",
		sql.Named("id", id),
	)
	return err
}

// Close closes the database connection pool.
func (c *Certdb) Close() error {
	return c.db.Close()
}
