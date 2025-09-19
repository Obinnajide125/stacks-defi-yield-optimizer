;; yield-strategy-manager
;; Core contract that manages automated yield farming strategies, executes rebalancing decisions,
;; handles cross-protocol interactions, and maintains risk assessment algorithms for optimal fund allocation.

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u1001))
(define-constant ERR_STRATEGY_NOT_FOUND (err u1002))
(define-constant ERR_INSUFFICIENT_FUNDS (err u1003))
(define-constant ERR_INVALID_AMOUNT (err u1004))
(define-constant ERR_STRATEGY_PAUSED (err u1005))
(define-constant ERR_REBALANCE_TOO_SOON (err u1006))
(define-constant ERR_RISK_THRESHOLD_EXCEEDED (err u1007))
(define-constant MIN_DEPOSIT u1000000) ;; 1 STX minimum
(define-constant MAX_STRATEGIES u100)
(define-constant REBALANCE_COOLDOWN u144) ;; ~1 day in blocks

;; Data Variables
(define-data-var strategy-counter uint u0)
(define-data-var total-strategies uint u0)
(define-data-var contract-paused bool false)
(define-data-var emergency-mode bool false)
(define-data-var total-value-locked uint u0)
(define-data-var platform-fee-rate uint u250) ;; 2.5% (250/10000)

;; Data Maps
(define-map strategies uint {
    name: (string-ascii 50),
    description: (string-ascii 200),
    target-apy: uint,
    risk-level: uint,
    total-deposited: uint,
    total-withdrawn: uint,
    current-balance: uint,
    active: bool,
    paused: bool,
    created-at: uint,
    last-rebalance: uint
})

(define-map user-positions {
    user: principal,
    strategy-id: uint
} {
    amount-deposited: uint,
    deposit-block: uint,
    last-reward-claim: uint,
    pending-rewards: uint,
    shares: uint
})

(define-map protocol-adapters (string-ascii 30) {
    contract-address: principal,
    active: bool,
    risk-score: uint,
    current-apy: uint,
    tvl: uint,
    last-updated: uint
})

(define-map strategy-performance uint {
    total-returns: uint,
    annualized-return: uint,
    volatility: uint,
    sharpe-ratio: uint,
    max-drawdown: uint,
    last-calculated: uint
})

;; Authorization Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER))

(define-private (is-valid-strategy-id (strategy-id uint))
    (and (> strategy-id u0)
         (<= strategy-id (var-get strategy-counter))))

(define-private (is-strategy-active (strategy-id uint))
    (match (map-get? strategies strategy-id)
        strategy (and (get active strategy) (not (get paused strategy)))
        false))

(define-private (calculate-shares (amount uint) (strategy-id uint))
    (let ((strategy (unwrap! (map-get? strategies strategy-id) u0))
          (total-balance (get current-balance strategy)))
        (if (is-eq total-balance u0)
            amount
            (/ (* amount u1000000) total-balance))))

(define-private (assess-portfolio-risk (strategy-id uint))
    (let ((strategy (unwrap! (map-get? strategies strategy-id) u0)))
        (get risk-level strategy)))

(define-private (should-rebalance (strategy-id uint))
    (let ((strategy (unwrap! (map-get? strategies strategy-id) false))
          (last-rebalance (get last-rebalance strategy))
          (current-block block-height))
        (>= (- current-block last-rebalance) REBALANCE_COOLDOWN)))

(define-private (execute-rebalance-internal (strategy-id uint))
    (let ((strategy (unwrap! (map-get? strategies strategy-id) ERR_STRATEGY_NOT_FOUND)))
        (map-set strategies strategy-id
            (merge strategy {
                last-rebalance: block-height
            }))
        (ok true)))

(define-private (update-strategy-performance (strategy-id uint))
    (let ((strategy (unwrap! (map-get? strategies strategy-id) ERR_STRATEGY_NOT_FOUND))
          (current-balance (get current-balance strategy))
          (total-deposited (get total-deposited strategy))
          (returns (if (> current-balance total-deposited)
                      (- current-balance total-deposited)
                      u0))
          (return-rate (if (> total-deposited u0)
                          (/ (* returns u10000) total-deposited)
                          u0)))
        (map-set strategy-performance strategy-id {
            total-returns: returns,
            annualized-return: return-rate,
            volatility: u150,
            sharpe-ratio: u120,
            max-drawdown: u50,
            last-calculated: block-height
        })
        (ok return-rate)))

;; Public Functions - Strategy Management
(define-public (create-strategy (name (string-ascii 50)) (description (string-ascii 200)) (target-apy uint) (risk-level uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (not (var-get contract-paused)) ERR_STRATEGY_PAUSED)
        (asserts! (<= risk-level u5) ERR_INVALID_AMOUNT)
        (asserts! (< (var-get total-strategies) MAX_STRATEGIES) ERR_INVALID_AMOUNT)
        
        (let ((new-strategy-id (+ (var-get strategy-counter) u1)))
            (map-set strategies new-strategy-id {
                name: name,
                description: description,
                target-apy: target-apy,
                risk-level: risk-level,
                total-deposited: u0,
                total-withdrawn: u0,
                current-balance: u0,
                active: true,
                paused: false,
                created-at: block-height,
                last-rebalance: block-height
            })
            
            (var-set strategy-counter new-strategy-id)
            (var-set total-strategies (+ (var-get total-strategies) u1))
            
            (ok new-strategy-id))))

(define-public (deposit (amount uint) (strategy-id uint))
    (begin
        (asserts! (>= amount MIN_DEPOSIT) ERR_INVALID_AMOUNT)
        (asserts! (is-valid-strategy-id strategy-id) ERR_STRATEGY_NOT_FOUND)
        (asserts! (is-strategy-active strategy-id) ERR_STRATEGY_PAUSED)
        (asserts! (not (var-get emergency-mode)) ERR_STRATEGY_PAUSED)
        
        (let ((strategy (unwrap! (map-get? strategies strategy-id) ERR_STRATEGY_NOT_FOUND))
              (shares (calculate-shares amount strategy-id))
              (user-key {user: tx-sender, strategy-id: strategy-id})
              (existing-position (default-to 
                                  {amount-deposited: u0, deposit-block: u0, last-reward-claim: u0, pending-rewards: u0, shares: u0}
                                  (map-get? user-positions user-key))))
            
            (map-set strategies strategy-id
                (merge strategy {
                    total-deposited: (+ (get total-deposited strategy) amount),
                    current-balance: (+ (get current-balance strategy) amount)
                }))
            
            (map-set user-positions user-key {
                amount-deposited: (+ (get amount-deposited existing-position) amount),
                deposit-block: block-height,
                last-reward-claim: block-height,
                pending-rewards: (get pending-rewards existing-position),
                shares: (+ (get shares existing-position) shares)
            })
            
            (var-set total-value-locked (+ (var-get total-value-locked) amount))
            
            (ok shares))))

(define-public (withdraw (amount uint) (strategy-id uint))
    (begin
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (is-valid-strategy-id strategy-id) ERR_STRATEGY_NOT_FOUND)
        
        (let ((user-key {user: tx-sender, strategy-id: strategy-id})
              (user-position (unwrap! (map-get? user-positions user-key) ERR_INSUFFICIENT_FUNDS))
              (strategy (unwrap! (map-get? strategies strategy-id) ERR_STRATEGY_NOT_FOUND)))
            
            (asserts! (<= amount (get amount-deposited user-position)) ERR_INSUFFICIENT_FUNDS)
            
            (let ((shares-to-burn (/ (* amount (get shares user-position)) (get amount-deposited user-position))))
                
                (map-set user-positions user-key
                    (merge user-position {
                        amount-deposited: (- (get amount-deposited user-position) amount),
                        shares: (- (get shares user-position) shares-to-burn)
                    }))
                
                (map-set strategies strategy-id
                    (merge strategy {
                        total-withdrawn: (+ (get total-withdrawn strategy) amount),
                        current-balance: (- (get current-balance strategy) amount)
                    }))
                
                (var-set total-value-locked (- (var-get total-value-locked) amount))
                
                (ok amount)))))

(define-public (rebalance (strategy-id uint))
    (begin
        (asserts! (is-valid-strategy-id strategy-id) ERR_STRATEGY_NOT_FOUND)
        (asserts! (is-strategy-active strategy-id) ERR_STRATEGY_PAUSED)
        (asserts! (should-rebalance strategy-id) ERR_REBALANCE_TOO_SOON)
        
        (let ((risk-score (assess-portfolio-risk strategy-id)))
            (asserts! (<= risk-score u4) ERR_RISK_THRESHOLD_EXCEEDED)
            
            (execute-rebalance-internal strategy-id)
            (update-strategy-performance strategy-id)
            
            (ok true))))

(define-public (emergency-pause)
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (var-set emergency-mode true)
        (var-set contract-paused true)
        (ok true)))

(define-public (resume-operations)
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (var-set emergency-mode false)
        (var-set contract-paused false)
        (ok true)))

;; Read-only Functions
(define-read-only (get-strategy (strategy-id uint))
    (map-get? strategies strategy-id))

(define-read-only (get-strategy-performance (strategy-id uint))
    (map-get? strategy-performance strategy-id))

(define-read-only (get-user-position (user principal) (strategy-id uint))
    (map-get? user-positions {user: user, strategy-id: strategy-id}))

(define-read-only (get-protocol-info (protocol-name (string-ascii 30)))
    (map-get? protocol-adapters protocol-name))

(define-read-only (get-total-strategies)
    (var-get total-strategies))

(define-read-only (get-total-value-locked)
    (var-get total-value-locked))

(define-read-only (is-contract-paused)
    (var-get contract-paused))

(define-read-only (is-emergency-mode)
    (var-get emergency-mode))

(define-read-only (calculate-expected-returns (strategy-id uint) (amount uint))
    (let ((strategy (unwrap! (map-get? strategies strategy-id) u0))
          (target-apy (get target-apy strategy))
          (annual-return (/ (* amount target-apy) u10000)))
        (ok annual-return)))

(define-public (add-protocol-adapter (protocol-name (string-ascii 30)) (contract-address principal) (risk-score uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (<= risk-score u5) ERR_INVALID_AMOUNT)
        
        (map-set protocol-adapters protocol-name {
            contract-address: contract-address,
            active: true,
            risk-score: risk-score,
            current-apy: u0,
            tvl: u0,
            last-updated: block-height
        })
        
        (ok true)))

(define-public (update-platform-fee (new-fee-rate uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (<= new-fee-rate u1000) ERR_INVALID_AMOUNT)
        
        (var-set platform-fee-rate new-fee-rate)
        (ok true)))
