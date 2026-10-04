package repository

import (
	"os"
	"testing"
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
