package repository

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

// connStringEnv names the environment variable holding the test database's
// connection string. `make test-db ENV=dev` sets it from the deployed resources.
const connStringEnv = "CERTDB_CONNECTION_STRING"

// newTestDB connects to the database named by CERTDB_CONNECTION_STRING and
// closes it when the test ends. Tests using it are skipped if the variable is unset.
func newTestDB(t *testing.T) *Certdb {
	t.Helper()

	connString := os.Getenv(connStringEnv)
	if connString == "" {
		t.Skipf("%s not set; skipping database test", connStringEnv)
	}

	db, err := New(connString)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return db
}

func TestNew(t *testing.T) {
	newTestDB(t)
}

func TestCertCrud(t *testing.T) {
	db := newTestDB(t)
	assert.NotNil(t, db) 
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel() 
	id, err  := db.RegisterDomain(ctx, "foobar.com")
	assert.Nil(t, err)
	assert.NotEqual(t, id, 0)
	cert, err := db.GetCertificateInfo(ctx, id)
	assert.Nil(t, err)
	assert.NotNil(t, cert)
	assert.Equal(t, "foobar.com", cert.Domain)
	assert.Nil(t, db.UnregisterDomain(ctx, id))
	_, err = db.GetCertificateInfo(ctx, id)
	assert.NotNil(t, err)
}
