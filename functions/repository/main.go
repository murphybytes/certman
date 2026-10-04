// Package repository provides access to the certman Azure SQL database.
package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	// Registers the "azuresql" driver, which supports Entra ID authentication.
	"github.com/microsoft/go-mssqldb/azuread"
)

const connectTimeout = 30 * time.Second

// Certdb is a handle to the certman database. It is safe for concurrent use.
type Certdb struct {
	db *sql.DB
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
	db, err := sql.Open(azuread.DriverName, connString)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("connecting to database: %w", err)
	}

	return &Certdb{db: db}, nil
}

// Close closes the database connection pool.
func (c *Certdb) Close() error {
	return c.db.Close()
}
