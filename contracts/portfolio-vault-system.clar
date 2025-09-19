;; portfolio-vault-system
;; Secure vault contract that holds user deposits, tracks individual portfolio compositions,
;; manages withdrawal queues, and implements emergency pause mechanisms for fund protection.

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u2001))
(define-constant ERR_PORTFOLIO_NOT_FOUND (err u2002))
(define-constant ERR_INSUFFICIENT_BALANCE (err u2003))
(define-constant ERR_INVALID_AMOUNT (err u2004))
(define-constant ERR_VAULT_PAUSED (err u2005))
(define-constant ERR_WITHDRAWAL_PENDING (err u2006))
(define-constant ERR_INVALID_RISK_LEVEL (err u2007))
(define-constant ERR_MAX_PORTFOLIOS_REACHED (err u2008))
(define-constant MIN_PORTFOLIO_BALANCE u1000000) ;; 1 STX minimum
(define-constant MAX_PORTFOLIOS_PER_USER u10)
(define-constant WITHDRAWAL_DELAY u144) ;; ~1 day in blocks
(define-constant EMERGENCY_WITHDRAWAL_FEE u500) ;; 5% fee (500/10000)

;; Data Variables
(define-data-var portfolio-counter uint u0)
(define-data-var total-portfolios uint u0)
(define-data-var vault-paused bool false)
(define-data-var emergency-mode bool false)
(define-data-var total-vault-balance uint u0)
(define-data-var withdrawal-queue-length uint u0)
(define-data-var vault-fee-rate uint u100) ;; 1% management fee (100/10000)

;; Data Maps
(define-map portfolios uint {
    owner: principal,
    total-balance: uint,
    available-balance: uint,
    locked-balance: uint,
    risk-level: uint, ;; 1-5 scale
    created-at: uint,
    last-rebalance: uint,
    status: (string-ascii 20), ;; "active", "paused", "liquidating"
    performance: {
        total-deposits: uint,
        total-withdrawals: uint,
        total-earnings: uint,
        fees-paid: uint
    },
    allocations: (list 20 {
        strategy-id: uint,
        amount: uint,
        percentage: uint
    })
})

(define-map user-portfolio-count principal uint)

(define-map withdrawal-requests uint {
    portfolio-id: uint,
    user: principal,
    amount: uint,
    request-block: uint,
    status: (string-ascii 20), ;; "pending", "approved", "executed", "cancelled"
    priority: uint,
    emergency: bool
})

(define-map vault-reserves (string-ascii 20) {
    total-amount: uint,
    available-amount: uint,
    reserved-amount: uint,
    last-updated: uint
})

(define-map portfolio-snapshots {
    portfolio-id: uint,
    timestamp: uint
} {
    balance: uint,
    allocations: (list 20 {strategy-id: uint, amount: uint, percentage: uint}),
    performance-metrics: {
        return-rate: uint,
        volatility: uint,
        sharpe-ratio: uint
    }
})

(define-map emergency-contacts principal {
    authorized: bool,
    permissions: (list 10 (string-ascii 30)),
    added-at: uint
})

;; Authorization Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER))

(define-private (is-portfolio-owner (portfolio-id uint))
    (match (map-get? portfolios portfolio-id)
        portfolio (is-eq tx-sender (get owner portfolio))
        false))

(define-private (is-emergency-contact)
    (match (map-get? emergency-contacts tx-sender)
        contact (get authorized contact)
        false))

;; Validation Functions
(define-private (is-valid-portfolio-id (portfolio-id uint))
    (and (> portfolio-id u0)
         (<= portfolio-id (var-get portfolio-counter))))

(define-private (is-portfolio-active (portfolio-id uint))
    (match (map-get? portfolios portfolio-id)
        portfolio (is-eq (get status portfolio) "active")
        false))

(define-private (can-user-create-portfolio (user principal))
    (let ((user-count (default-to u0 (map-get? user-portfolio-count user))))
        (< user-count MAX_PORTFOLIOS_PER_USER)))

;; Portfolio Management Functions
(define-private (calculate-portfolio-value (portfolio-id uint))
    (match (map-get? portfolios portfolio-id)
        portfolio
            (let ((allocations (get allocations portfolio)))
                (fold calculate-allocation-value allocations u0))
        u0))

(define-private (calculate-allocation-value (allocation {strategy-id: uint, amount: uint, percentage: uint}) (acc uint))
    ;; In production, this would fetch current value from strategy contracts
    (+ acc (get amount allocation)))

(define-private (update-portfolio-performance (portfolio-id uint))
    (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND))
          (current-value (calculate-portfolio-value portfolio-id))
          (performance (get performance portfolio))
          (total-invested (get total-deposits performance))
          (total-withdrawn (get total-withdrawals performance))
          (net-invested (- total-invested total-withdrawn))
          (earnings (if (> current-value net-invested)
                        (- current-value net-invested)
                        u0)))
        
        (map-set portfolios portfolio-id
            (merge portfolio {
                performance: (merge performance {
                    total-earnings: earnings
                })
            }))
        (ok earnings)))

;; Withdrawal Queue Management
(define-private (add-to-withdrawal-queue (portfolio-id uint) (amount uint) (is-emergency bool))
    (let ((new-request-id (+ (var-get withdrawal-queue-length) u1))
          (priority (if is-emergency u1 u5)))
        
        (map-set withdrawal-requests new-request-id {
            portfolio-id: portfolio-id,
            user: tx-sender,
            amount: amount,
            request-block: burn-block-height,
            status: "pending",
            priority: priority,
            emergency: is-emergency
        })
        
        (var-set withdrawal-queue-length new-request-id)
        (ok new-request-id)))

(define-private (process-withdrawal-request (request-id uint))
    (let ((request (unwrap! (map-get? withdrawal-requests request-id) ERR_WITHDRAWAL_PENDING))
          (portfolio-id (get portfolio-id request))
          (portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND))
          (amount (get amount request)))
        
        ;; Check if sufficient time has passed (unless emergency)
        (asserts! (or (get emergency request)
                     (>= (- burn-block-height (get request-block request)) WITHDRAWAL_DELAY))
                 ERR_WITHDRAWAL_PENDING)
        
        ;; Check sufficient balance
        (asserts! (<= amount (get available-balance portfolio)) ERR_INSUFFICIENT_BALANCE)
        
        ;; Calculate fees
        (let ((fee (if (get emergency request)
                       (/ (* amount EMERGENCY_WITHDRAWAL_FEE) u10000)
                       u0))
              (net-amount (- amount fee)))
            
            ;; Update portfolio
            (map-set portfolios portfolio-id
                (merge portfolio {
                    available-balance: (- (get available-balance portfolio) amount),
                    total-balance: (- (get total-balance portfolio) amount),
                    performance: (merge (get performance portfolio) {
                        total-withdrawals: (+ (get total-withdrawals (get performance portfolio)) amount),
                        fees-paid: (+ (get fees-paid (get performance portfolio)) fee)
                    })
                }))
            
            ;; Update withdrawal request status
            (map-set withdrawal-requests request-id
                (merge request {
                    status: "executed"
                }))
            
            ;; Update total vault balance
            (var-set total-vault-balance (- (var-get total-vault-balance) amount))
            
            (ok net-amount))))

;; Public Functions - Portfolio Management
(define-public (create-portfolio (initial-deposit uint) (risk-level uint))
    (begin
        (asserts! (not (var-get vault-paused)) ERR_VAULT_PAUSED)
        (asserts! (>= initial-deposit MIN_PORTFOLIO_BALANCE) ERR_INVALID_AMOUNT)
        (asserts! (and (>= risk-level u1) (<= risk-level u5)) ERR_INVALID_RISK_LEVEL)
        (asserts! (can-user-create-portfolio tx-sender) ERR_MAX_PORTFOLIOS_REACHED)
        
        (let ((new-portfolio-id (+ (var-get portfolio-counter) u1))
              (user-count (default-to u0 (map-get? user-portfolio-count tx-sender))))
            
            ;; Create new portfolio
            (map-set portfolios new-portfolio-id {
                owner: tx-sender,
                total-balance: initial-deposit,
                available-balance: initial-deposit,
                locked-balance: u0,
                risk-level: risk-level,
                created-at: burn-block-height,
                last-rebalance: burn-block-height,
                status: "active",
                performance: {
                    total-deposits: initial-deposit,
                    total-withdrawals: u0,
                    total-earnings: u0,
                    fees-paid: u0
                },
                allocations: (list)
            })
            
            ;; Update counters
            (var-set portfolio-counter new-portfolio-id)
            (var-set total-portfolios (+ (var-get total-portfolios) u1))
            (var-set total-vault-balance (+ (var-get total-vault-balance) initial-deposit))
            
            ;; Update user portfolio count
            (map-set user-portfolio-count tx-sender (+ user-count u1))
            
            (ok new-portfolio-id))))

(define-public (add-funds (portfolio-id uint) (amount uint))
    (begin
        (asserts! (is-valid-portfolio-id portfolio-id) ERR_PORTFOLIO_NOT_FOUND)
        (asserts! (is-portfolio-owner portfolio-id) ERR_NOT_AUTHORIZED)
        (asserts! (is-portfolio-active portfolio-id) ERR_VAULT_PAUSED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (not (var-get vault-paused)) ERR_VAULT_PAUSED)
        
        (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND))
              (performance (get performance portfolio)))
            
            ;; Update portfolio balances
            (map-set portfolios portfolio-id
                (merge portfolio {
                    total-balance: (+ (get total-balance portfolio) amount),
                    available-balance: (+ (get available-balance portfolio) amount),
                    performance: (merge performance {
                        total-deposits: (+ (get total-deposits performance) amount)
                    })
                }))
            
            ;; Update total vault balance
            (var-set total-vault-balance (+ (var-get total-vault-balance) amount))
            
            (ok true))))

(define-public (request-withdrawal (portfolio-id uint) (amount uint))
    (begin
        (asserts! (is-valid-portfolio-id portfolio-id) ERR_PORTFOLIO_NOT_FOUND)
        (asserts! (is-portfolio-owner portfolio-id) ERR_NOT_AUTHORIZED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        
        (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND)))
            (asserts! (<= amount (get available-balance portfolio)) ERR_INSUFFICIENT_BALANCE)
            
            ;; Add to withdrawal queue
            (add-to-withdrawal-queue portfolio-id amount false))))

(define-public (emergency-withdrawal (portfolio-id uint) (amount uint))
    (begin
        (asserts! (is-valid-portfolio-id portfolio-id) ERR_PORTFOLIO_NOT_FOUND)
        (asserts! (is-portfolio-owner portfolio-id) ERR_NOT_AUTHORIZED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        
        (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND)))
            (asserts! (<= amount (get available-balance portfolio)) ERR_INSUFFICIENT_BALANCE)
            
            ;; Add to withdrawal queue with emergency flag
            (add-to-withdrawal-queue portfolio-id amount true))))

(define-public (execute-withdrawal (request-id uint))
    (begin
        (asserts! (not (var-get vault-paused)) ERR_VAULT_PAUSED)
        (process-withdrawal-request request-id)))

(define-public (allocate-funds (portfolio-id uint) (strategy-id uint) (amount uint))
    (begin
        (asserts! (is-valid-portfolio-id portfolio-id) ERR_PORTFOLIO_NOT_FOUND)
        (asserts! (is-portfolio-owner portfolio-id) ERR_NOT_AUTHORIZED)
        (asserts! (is-portfolio-active portfolio-id) ERR_VAULT_PAUSED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        
        (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND)))
            (asserts! (<= amount (get available-balance portfolio)) ERR_INSUFFICIENT_BALANCE)
            
            ;; Update balances
            (map-set portfolios portfolio-id
                (merge portfolio {
                    available-balance: (- (get available-balance portfolio) amount),
                    locked-balance: (+ (get locked-balance portfolio) amount),
                    last-rebalance: burn-block-height
                }))
            
            (ok true))))

;; Emergency Functions
(define-public (emergency-pause-vault)
    (begin
        (asserts! (or (is-contract-owner) (is-emergency-contact)) ERR_NOT_AUTHORIZED)
        (var-set vault-paused true)
        (var-set emergency-mode true)
        (ok true)))

(define-public (resume-vault-operations)
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (var-set vault-paused false)
        (var-set emergency-mode false)
        (ok true)))

(define-public (add-emergency-contact (contact principal) (permissions (list 10 (string-ascii 30))))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        
        (map-set emergency-contacts contact {
            authorized: true,
            permissions: permissions,
            added-at: burn-block-height
        })
        
        (ok true)))

;; Read-only Functions
(define-read-only (get-portfolio (portfolio-id uint))
    (map-get? portfolios portfolio-id))

(define-read-only (get-portfolio-composition (portfolio-id uint))
    (match (map-get? portfolios portfolio-id)
        portfolio (some {
            total-balance: (get total-balance portfolio),
            available-balance: (get available-balance portfolio),
            locked-balance: (get locked-balance portfolio),
            allocations: (get allocations portfolio),
            performance: (get performance portfolio)
        })
        none))

(define-read-only (get-withdrawal-request (request-id uint))
    (map-get? withdrawal-requests request-id))

(define-read-only (get-user-portfolios (user principal))
    (map-get? user-portfolio-count user))

(define-read-only (get-total-vault-balance)
    (var-get total-vault-balance))

(define-read-only (is-vault-paused)
    (var-get vault-paused))

(define-read-only (is-emergency-mode)
    (var-get emergency-mode))

(define-read-only (get-vault-reserves (asset-type (string-ascii 20)))
    (map-get? vault-reserves asset-type))

(define-read-only (calculate-withdrawal-fee (amount uint) (is-emergency bool))
    (if is-emergency
        (/ (* amount EMERGENCY_WITHDRAWAL_FEE) u10000)
        u0))

;; Administrative Functions
(define-public (update-vault-fee (new-fee-rate uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (<= new-fee-rate u1000) ERR_INVALID_AMOUNT) ;; Max 10%
        
        (var-set vault-fee-rate new-fee-rate)
        (ok true)))

(define-public (force-liquidate-portfolio (portfolio-id uint))
    (begin
        (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
        (asserts! (is-valid-portfolio-id portfolio-id) ERR_PORTFOLIO_NOT_FOUND)
        
        (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND)))
            (map-set portfolios portfolio-id
                (merge portfolio {
                    status: "liquidating"
                }))
            
            (ok true))))

;; Snapshot Functions for Analytics
(define-public (create-portfolio-snapshot (portfolio-id uint))
    (begin
        (asserts! (is-valid-portfolio-id portfolio-id) ERR_PORTFOLIO_NOT_FOUND)
        (asserts! (is-portfolio-owner portfolio-id) ERR_NOT_AUTHORIZED)
        
        (let ((portfolio (unwrap! (map-get? portfolios portfolio-id) ERR_PORTFOLIO_NOT_FOUND))
              (current-value (calculate-portfolio-value portfolio-id)))
            
            (map-set portfolio-snapshots {
                portfolio-id: portfolio-id,
                timestamp: burn-block-height
            } {
                balance: current-value,
                allocations: (get allocations portfolio),
                performance-metrics: {
                    return-rate: u0, ;; Calculated separately
                    volatility: u0,  ;; Calculated separately
                    sharpe-ratio: u0 ;; Calculated separately
                }
            })
            
            (ok true))))
