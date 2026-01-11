;; Infinity Art - Contribution-Weighted Ownership Platform
;; A decentralized collaborative creation platform with dynamic revenue distribution

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-percentage (err u104))
(define-constant err-insufficient-balance (err u105))

;; Data Variables
(define-data-var platform-fee-percentage uint u250) ;; 2.5% (basis points)
(define-data-var next-artwork-id uint u0)
(define-data-var next-contribution-id uint u0)

;; Data Maps
(define-map artworks
  { artwork-id: uint }
  {
    title: (string-ascii 100),
    creator: principal,
    total-contributors: uint,
    total-revenue: uint,
    active: bool,
    created-at: uint
  }
)

(define-map contributions
  { contribution-id: uint }
  {
    artwork-id: uint,
    contributor: principal,
    contribution-percentage: uint,
    reputation-staked: uint,
    validated: bool,
    timestamp: uint
  }
)

(define-map contributor-shares
  { artwork-id: uint, contributor: principal }
  { share-percentage: uint }
)

(define-map artwork-revenues
  { artwork-id: uint }
  { total-collected: uint }
)

(define-map contributor-balances
  { artwork-id: uint, contributor: principal }
  { earned: uint, withdrawn: uint }
)

(define-map reputation-tokens
  { holder: principal }
  { balance: uint }
)

;; Read-only functions
(define-read-only (get-artwork (artwork-id uint))
  (map-get? artworks { artwork-id: artwork-id })
)

(define-read-only (get-contribution (contribution-id uint))
  (map-get? contributions { contribution-id: contribution-id })
)

(define-read-only (get-contributor-share (artwork-id uint) (contributor principal))
  (default-to 
    { share-percentage: u0 }
    (map-get? contributor-shares { artwork-id: artwork-id, contributor: contributor })
  )
)

(define-read-only (get-contributor-balance (artwork-id uint) (contributor principal))
  (default-to
    { earned: u0, withdrawn: u0 }
    (map-get? contributor-balances { artwork-id: artwork-id, contributor: contributor })
  )
)

(define-read-only (get-reputation-balance (holder principal))
  (default-to
    { balance: u0 }
    (map-get? reputation-tokens { holder: holder })
  )
)

(define-read-only (get-platform-fee)
  (var-get platform-fee-percentage)
)

;; Public functions

;; Create new collaborative artwork
(define-public (create-artwork (title (string-ascii 100)))
  (let
    (
      (artwork-id (var-get next-artwork-id))
    )
    (map-set artworks
      { artwork-id: artwork-id }
      {
        title: title,
        creator: tx-sender,
        total-contributors: u0,
        total-revenue: u0,
        active: true,
        created-at: block-height
      }
    )
    (var-set next-artwork-id (+ artwork-id u1))
    (ok artwork-id)
  )
)

;; Add contribution to artwork
(define-public (add-contribution (artwork-id uint) (contribution-percentage uint) (reputation-stake uint))
  (let
    (
      (artwork (unwrap! (map-get? artworks { artwork-id: artwork-id }) err-not-found))
      (contribution-id (var-get next-contribution-id))
      (current-reputation (get balance (get-reputation-balance tx-sender)))
    )
    (asserts! (<= contribution-percentage u10000) err-invalid-percentage)
    (asserts! (>= current-reputation reputation-stake) err-insufficient-balance)
    
    (map-set contributions
      { contribution-id: contribution-id }
      {
        artwork-id: artwork-id,
        contributor: tx-sender,
        contribution-percentage: contribution-percentage,
        reputation-staked: reputation-stake,
        validated: false,
        timestamp: block-height
      }
    )
    
    (map-set reputation-tokens
      { holder: tx-sender }
      { balance: (- current-reputation reputation-stake) }
    )
    
    (var-set next-contribution-id (+ contribution-id u1))
    (ok contribution-id)
  )
)

;; Validate contribution (by artwork creator or validators)
(define-public (validate-contribution (contribution-id uint))
  (let
    (
      (contribution (unwrap! (map-get? contributions { contribution-id: contribution-id }) err-not-found))
      (artwork-id (get artwork-id contribution))
      (artwork (unwrap! (map-get? artworks { artwork-id: artwork-id }) err-not-found))
      (contributor (get contributor contribution))
      (contrib-pct (get contribution-percentage contribution))
    )
    (asserts! (is-eq tx-sender (get creator artwork)) err-unauthorized)
    
    (map-set contributions
      { contribution-id: contribution-id }
      (merge contribution { validated: true })
    )
    
    (map-set contributor-shares
      { artwork-id: artwork-id, contributor: contributor }
      { share-percentage: contrib-pct }
    )
    
    (map-set artworks
      { artwork-id: artwork-id }
      (merge artwork { total-contributors: (+ (get total-contributors artwork) u1) })
    )
    
    (ok true)
  )
)

;; Distribute revenue to artwork
(define-public (distribute-revenue (artwork-id uint) (amount uint))
  (let
    (
      (artwork (unwrap! (map-get? artworks { artwork-id: artwork-id }) err-not-found))
      (platform-fee (/ (* amount (var-get platform-fee-percentage)) u10000))
      (distributable (- amount platform-fee))
    )
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    (map-set artwork-revenues
      { artwork-id: artwork-id }
      { total-collected: (+ (default-to u0 (get total-collected (map-get? artwork-revenues { artwork-id: artwork-id }))) distributable) }
    )
    
    (map-set artworks
      { artwork-id: artwork-id }
      (merge artwork { total-revenue: (+ (get total-revenue artwork) distributable) })
    )
    
    (ok distributable)
  )
)

;; Claim earnings for contributor
(define-public (claim-earnings (artwork-id uint))
  (let
    (
      (share-info (get-contributor-share artwork-id tx-sender))
      (balance-info (get-contributor-balance artwork-id tx-sender))
      (artwork-revenue (default-to { total-collected: u0 } (map-get? artwork-revenues { artwork-id: artwork-id })))
      (share-pct (get share-percentage share-info))
      (total-earned (/ (* (get total-collected artwork-revenue) share-pct) u10000))
      (already-withdrawn (get withdrawn balance-info))
      (claimable (- total-earned already-withdrawn))
    )
    (asserts! (> claimable u0) err-insufficient-balance)
    
    (try! (as-contract (stx-transfer? claimable tx-sender (unwrap-panic (some tx-sender)))))
    
    (map-set contributor-balances
      { artwork-id: artwork-id, contributor: tx-sender }
      { earned: total-earned, withdrawn: total-earned }
    )
    
    (ok claimable)
  )
)

;; Mint reputation tokens (for initial distribution or rewards)
(define-public (mint-reputation (recipient principal) (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (let
      (
        (current-balance (get balance (get-reputation-balance recipient)))
      )
      (map-set reputation-tokens
        { holder: recipient }
        { balance: (+ current-balance amount) }
      )
      (ok true)
    )
  )
)

;; Admin function to update platform fee
(define-public (set-platform-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-fee u1000) err-invalid-percentage) ;; Max 10%
    (var-set platform-fee-percentage new-fee)
    (ok true)
  )
)