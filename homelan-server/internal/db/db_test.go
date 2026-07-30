package db

import (
	"crypto/rand"
	"io"
	"os"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func TestUserAndPasswordMigration(t *testing.T) {
	// Create an encrypted database file in a temporary folder
	tempFile, err := os.CreateTemp("", "messages*.db")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tempFile.Name())
	tempFile.Close()

	key := make([]byte, 32)
	io.ReadFull(rand.Reader, key)

	database, err := New(tempFile.Name(), key)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()

	// 1. Create a user with raw/plaintext password for migration simulation
	username := "legacy_user"
	plaintextPassword := "secret_legacy_123"

	// CreateUser expects password hash. Let's insert a plaintext password first into DB
	// to simulate pre-migration state.
	now := time.Now().Unix()
	_, err = database.conn.Exec(
		`INSERT INTO users (username, password_hash, created_at, last_seen, is_admin) 
		 VALUES (?, ?, ?, ?, 0)`,
		username, plaintextPassword, now, now,
	)
	if err != nil {
		t.Fatal(err)
	}

	// 2. Fetch user and verify they have legacy plaintext password
	user, err := database.GetUserByUsername(username)
	if err != nil {
		t.Fatal(err)
	}
	if user == nil {
		t.Fatal("user not found")
	}
	if user.PasswordHash != plaintextPassword {
		t.Errorf("expected plaintext password, got %s", user.PasswordHash)
	}

	// 3. Simulate migration: check if password matches as plaintext
	isCorrect := false
	err = bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(plaintextPassword))
	if err != nil {
		// Compare as plaintext
		if user.PasswordHash == plaintextPassword {
			isCorrect = true
			// Migrate to secure hash
			hashedBytes, hashErr := bcrypt.GenerateFromPassword([]byte(plaintextPassword), bcrypt.DefaultCost)
			if hashErr == nil {
				err = database.UpdateUserPassword(user.ID, string(hashedBytes))
				if err != nil {
					t.Fatal(err)
				}
				// Refresh in-memory password hash
				user.PasswordHash = string(hashedBytes)
			}
		}
	}

	if !isCorrect {
		t.Fatal("migration comparison failed")
	}

	// 4. Verify password is now secure bcrypt hash in database
	userMigrated, err := database.GetUserByUsername(username)
	if err != nil {
		t.Fatal(err)
	}
	err = bcrypt.CompareHashAndPassword([]byte(userMigrated.PasswordHash), []byte(plaintextPassword))
	if err != nil {
		t.Errorf("failed to verify migrated bcrypt password: %v", err)
	}

	// 5. Test creation of a new user (which automatically hashes)
	newUser, err := database.CreateUser("new_user", "secure_pwd_456", false)
	if err != nil {
		t.Fatal(err)
	}
	err = bcrypt.CompareHashAndPassword([]byte(newUser.PasswordHash), []byte("secure_pwd_456"))
	if err != nil {
		t.Errorf("expected newly created user to have hashed password: %v", err)
	}
}

func TestSessions(t *testing.T) {
	tempFile, err := os.CreateTemp("", "messages*.db")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tempFile.Name())
	tempFile.Close()

	key := make([]byte, 32)
	io.ReadFull(rand.Reader, key)

	database, err := New(tempFile.Name(), key)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()

	user, err := database.CreateUser("test_user", "password123", false)
	if err != nil {
		t.Fatal(err)
	}

	// Create Session
	tokenHash := "some_sha256_hash_of_token"
	session, err := database.CreateSession(user.ID, "device_001", tokenHash, 1*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if session.UserID != user.ID {
		t.Errorf("expected userID %d, got %d", user.ID, session.UserID)
	}
	if session.TokenHash != tokenHash {
		t.Errorf("expected tokenHash %s, got %s", tokenHash, session.TokenHash)
	}

	// Fetch Session
	s, err := database.GetSessionByTokenHash(tokenHash)
	if err != nil {
		t.Fatal(err)
	}
	if s == nil {
		t.Fatal("expected session to be found")
	}
	if s.DeviceID != "device_001" {
		t.Errorf("expected deviceID device_001, got %s", s.DeviceID)
	}

	// Revoke Session
	err = database.RevokeSession(tokenHash)
	if err != nil {
		t.Fatal(err)
	}

	sRevoked, err := database.GetSessionByTokenHash(tokenHash)
	if err != nil {
		t.Fatal(err)
	}
	if !sRevoked.IsRevoked {
		t.Error("expected session to be revoked")
	}
}
