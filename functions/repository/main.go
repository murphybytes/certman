// Package repository provides access to the certman Azure SQL database.
package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	// Registers the "azuresql" driver, which supports Entra ID authentication.
	// "github.com/microsoft/go-mssqldb/azuread"
	
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
func New(connString string) (*Certdb, error) {
	db, err := sqlx.Open(azuread.DriverName, connString)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("connecting to database: %w", err)
	}

	return &Certdb{db: db}, nil
}

func (c *Certdb) RegisterDomain(ctx context.Context, domainName string) (int32,error) {
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

func (c *Certdb) GetCertificateInfo(ctx context.Context, id int32) (*Certificate, error) {
	var certInfo Certificate
	err := c.db.GetContext(ctx, 
		&certInfo,
		"SELECT id, domain, state, created, modified FROM System.tbl_cert WHERE id = @id",
		sql.Named("id",id),
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
