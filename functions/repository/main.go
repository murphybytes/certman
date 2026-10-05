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

// Certdb is a handle to the certman database. It is safe for concurrent use.
type Certdb struct {
	db *sqlx.DB
}

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

func (c *Certdb) RegisterDomain(ctx context.Context, domainName string) (int32, error) {
	query := `
			INSERT INTO  System.tbl_cert (domain)
			OUTPUT INSERTED.id 
			VALUES (@domain);
	`
	var insertedID int32

	err := c.db.QueryRowxContext(ctx, query, sql.Named("domain", domainName)).Scan(&insertedID)
	if err != nil {
		return 0, err
	}
	return insertedID, nil
}

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

func (c *Certdb) GetCertificateInfo(ctx context.Context, id int32) (*Certificate, error) {
	var certInfo Certificate
	err := c.db.GetContext(ctx,
		&certInfo,
		"SELECT id, domain, state, created, modified FROM System.tbl_cert WHERE id = @id",
		sql.Named("id", id),
	)
	return &certInfo, err
}

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
