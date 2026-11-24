package sync

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"
)

const (
	nonceTTL         = 30 * time.Second
	maxNonces        = 64
	maxFailures      = 5
	lockDuration     = 60 * time.Second
	HeaderNonce      = "X-Whim-Nonce"
	HeaderProof      = "X-Whim-Proof"
	HeaderPeerID     = "X-Whim-Peer-ID"
	HeaderPairIntent = "X-Whim-Pair"
)

type clientAuthState struct {
	failures    int
	lockedUntil time.Time
}

// Auth manages 6-digit pairing code verification with one-time nonces and per-client lockout.
type Auth struct {
	mu      sync.Mutex
	code    string
	nonces  map[string]time.Time
	clients map[string]*clientAuthState
	nowFn   func() time.Time
}

// NewAuth creates an Auth instance with the given 6-digit code.
func NewAuth(code string) *Auth {
	return &Auth{
		code:    NormalizeCode(code),
		nonces:  make(map[string]time.Time),
		clients: make(map[string]*clientAuthState),
		nowFn:   time.Now,
	}
}

// GenerateCode produces a cryptographically random 6-digit pairing code.
func GenerateCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "482913"
	}
	return fmt.Sprintf("%06d", n.Int64())
}

// NormalizeCode strips whitespace/hyphens and keeps digits only.
func NormalizeCode(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ComputeProof computes HMAC-SHA256(key=code, msg=nonce) as lowercase hex.
func ComputeProof(code, nonce string) string {
	mac := hmac.New(sha256.New, []byte(NormalizeCode(code)))
	mac.Write([]byte(nonce))
	return hex.EncodeToString(mac.Sum(nil))
}

// SetCode updates the active pairing code and resets lockout state.
func (a *Auth) SetCode(code string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.code = NormalizeCode(code)
	a.clients = make(map[string]*clientAuthState)
	a.nonces = make(map[string]time.Time)
}

// Code returns the active normalized pairing code.
func (a *Auth) Code() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.code
}

// IssueNonce creates a 16-byte random hex nonce valid for 30 seconds.
func (a *Auth) IssueNonce() string {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.nowFn()
	for k, exp := range a.nonces {
		if now.After(exp) {
			delete(a.nonces, k)
		}
	}
	if len(a.nonces) >= maxNonces {
		var oldestKey string
		var oldestExp time.Time
		for k, exp := range a.nonces {
			if oldestKey == "" || exp.Before(oldestExp) {
				oldestKey = k
				oldestExp = exp
			}
		}
		if oldestKey != "" {
			delete(a.nonces, oldestKey)
		}
	}

	var raw [16]byte
	_, _ = rand.Read(raw[:])
	nonce := hex.EncodeToString(raw[:])
	a.nonces[nonce] = now.Add(nonceTTL)
	return nonce
}

// VerifyResult indicates the outcome of verifying a request proof.
type VerifyResult struct {
	OK               bool
	Locked           bool
	RetryAfterSecond int
}

// Verify checks a one-time nonce and HMAC proof in constant time using the default client bucket.
func (a *Auth) Verify(nonce, proof string) VerifyResult {
	return a.VerifyFrom("default", nonce, proof)
}

// VerifyFrom checks a one-time nonce and HMAC proof with per-client lockout isolation
// so one misconfigured device never locks out other paired devices.
func (a *Auth) VerifyFrom(clientKey, nonce, proof string) VerifyResult {
	a.mu.Lock()
	defer a.mu.Unlock()

	if clientKey == "" {
		clientKey = "default"
	}
	st, ok := a.clients[clientKey]
	if !ok {
		st = &clientAuthState{}
		a.clients[clientKey] = st
	}

	now := a.nowFn()
	if now.Before(st.lockedUntil) {
		rem := int(st.lockedUntil.Sub(now).Seconds()) + 1
		return VerifyResult{OK: false, Locked: true, RetryAfterSecond: rem}
	}

	exp, exists := a.nonces[nonce]
	if !exists || now.After(exp) {
		delete(a.nonces, nonce)
		return a.recordFailureLocked(st, now)
	}
	// One-time use: consume immediately.
	delete(a.nonces, nonce)

	expected := ComputeProof(a.code, nonce)
	if !hmac.Equal([]byte(strings.ToLower(strings.TrimSpace(proof))), []byte(expected)) {
		return a.recordFailureLocked(st, now)
	}

	st.failures = 0
	return VerifyResult{OK: true}
}

func (a *Auth) recordFailureLocked(st *clientAuthState, now time.Time) VerifyResult {
	st.failures++
	if st.failures >= maxFailures {
		st.lockedUntil = now.Add(lockDuration)
		st.failures = 0
		return VerifyResult{OK: false, Locked: true, RetryAfterSecond: int(lockDuration.Seconds())}
	}
	return VerifyResult{OK: false}
}
