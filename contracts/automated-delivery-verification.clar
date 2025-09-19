;; automated-delivery-verification.clar
;; Automated Delivery Verification Smart Contract
;; Manages shipping contracts, payment escrow, and automated delivery verification
;; Handles multi-party signatures, condition-based settlements, and dispute resolution

;; Constants and Error Codes
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_NOT_FOUND (err u201))
(define-constant ERR_INVALID_AMOUNT (err u202))
(define-constant ERR_INSUFFICIENT_FUNDS (err u203))
(define-constant ERR_SHIPMENT_ALREADY_EXISTS (err u204))
(define-constant ERR_INVALID_PARTIES (err u205))
(define-constant ERR_SHIPMENT_NOT_ACTIVE (err u206))
(define-constant ERR_ALREADY_CONFIRMED (err u207))
(define-constant ERR_DELIVERY_TIMEOUT (err u208))
(define-constant ERR_CONDITION_VIOLATION (err u209))
(define-constant ERR_DISPUTE_ACTIVE (err u210))
(define-constant ERR_INVALID_SIGNATURE (err u211))

;; Shipment parameters
(define-constant MIN_SHIPMENT_VALUE u100000) ;; 0.1 STX minimum
(define-constant MAX_DELIVERY_DELAY u14400) ;; ~100 days in blocks
(define-constant DISPUTE_RESOLUTION_PERIOD u1440) ;; ~10 days in blocks
(define-constant CONDITION_PENALTY_RATE u5) ;; 5% penalty per condition violation
(define-constant PLATFORM_FEE_RATE u250) ;; 2.5% platform fee
(define-constant INSURANCE_RATE u100) ;; 1% insurance rate

;; Shipment and contract data structures
(define-map shipping-contracts
    { shipment-id: (string-ascii 64) }
    {
        shipper: principal,
        carrier: principal,
        receiver: principal,
        container-id: (string-ascii 32),
        origin-port: (string-ascii 50),
        destination-port: (string-ascii 50),
        cargo-description: (string-ascii 200),
        total-value: uint,
        escrow-amount: uint,
        expected-delivery: uint,
        created-at: uint,
        status: (string-ascii 20),
        is-insured: bool
    }
)

(define-map delivery-conditions
    { shipment-id: (string-ascii 64) }
    {
        temperature-min: int,
        temperature-max: int,
        humidity-max: uint,
        shock-max: uint,
        delivery-window-start: uint,
        delivery-window-end: uint,
        special-handling: (string-ascii 100),
        documentation-required: (list 5 (string-ascii 50))
    }
)

(define-map delivery-confirmations
    { shipment-id: (string-ascii 64), confirmer: principal }
    {
        confirmation-type: (string-ascii 30),
        confirmed-at: uint,
        signature-hash: (buff 64),
        notes: (string-ascii 300),
        condition-rating: uint,
        photographic-evidence: (buff 32)
    }
)

(define-map condition-violations
    { shipment-id: (string-ascii 64), violation-id: uint }
    {
        violation-type: (string-ascii 50),
        detected-at: uint,
        severity-level: uint,
        measured-value: int,
        threshold-value: int,
        penalty-amount: uint,
        is-disputed: bool
    }
)

(define-map payment-escrow
    { shipment-id: (string-ascii 64) }
    {
        total-amount: uint,
        carrier-payment: uint,
        platform-fee: uint,
        insurance-fee: uint,
        penalty-deductions: uint,
        final-amount: uint,
        is-released: bool,
        released-at: uint
    }
)

(define-map dispute-records
    { shipment-id: (string-ascii 64) }
    {
        initiated-by: principal,
        dispute-reason: (string-ascii 200),
        created-at: uint,
        resolution-deadline: uint,
        arbitrator: principal,
        status: (string-ascii 20),
        resolution: (string-ascii 500),
        resolved-at: uint
    }
)

;; Global counters and statistics
(define-data-var total-shipments uint u0)
(define-data-var completed-deliveries uint u0)
(define-data-var total-escrow-amount uint u0)
(define-data-var total-penalties uint u0)
(define-data-var next-violation-id uint u1)

;; Private helper functions
(define-private (calculate-platform-fee (amount uint))
    (/ (* amount PLATFORM_FEE_RATE) u10000)
)

(define-private (calculate-insurance-fee (amount uint))
    (/ (* amount INSURANCE_RATE) u10000)
)

(define-private (calculate-condition-penalty (violation-count uint) (shipment-value uint))
    (let (
        (penalty-percentage (* violation-count CONDITION_PENALTY_RATE))
        (max-penalty (/ shipment-value u5)) ;; Max 20% penalty
    )
        (if (< (* shipment-value penalty-percentage) (* max-penalty u100))
            (/ (* shipment-value penalty-percentage) u100)
            max-penalty
        )
    )
)

(define-private (validate-delivery-parties (shipper principal) (carrier principal) (receiver principal))
    (and
        (not (is-eq shipper carrier))
        (not (is-eq shipper receiver))
        (not (is-eq carrier receiver))
    )
)

(define-private (check-all-confirmations (shipment-id (string-ascii 64)))
    (let (
        (contract-info (map-get? shipping-contracts {shipment-id: shipment-id}))
    )
        (match contract-info
            contract
                (and
                    (is-some (map-get? delivery-confirmations {shipment-id: shipment-id, confirmer: (get shipper contract)}))
                    (is-some (map-get? delivery-confirmations {shipment-id: shipment-id, confirmer: (get carrier contract)}))
                    (is-some (map-get? delivery-confirmations {shipment-id: shipment-id, confirmer: (get receiver contract)}))
                )
            false
        )
    )
)

(define-private (update-shipment-status (shipment-id (string-ascii 64)) (new-status (string-ascii 20)))
    (match (map-get? shipping-contracts {shipment-id: shipment-id})
        contract
            (map-set shipping-contracts
                {shipment-id: shipment-id}
                (merge contract {status: new-status})
            )
        false
    )
)

;; Public functions for shipment management
(define-public (create-shipping-contract
    (shipment-id (string-ascii 64))
    (carrier principal)
    (receiver principal)
    (container-id (string-ascii 32))
    (origin-port (string-ascii 50))
    (destination-port (string-ascii 50))
    (cargo-description (string-ascii 200))
    (shipment-value uint)
    (expected-delivery-blocks uint)
    (is-insured bool)
)
    (let (
        (existing-contract (map-get? shipping-contracts {shipment-id: shipment-id}))
        (platform-fee (calculate-platform-fee shipment-value))
        (insurance-fee (if is-insured (calculate-insurance-fee shipment-value) u0))
        (total-escrow (+ shipment-value platform-fee insurance-fee))
    )
        (asserts! (is-none existing-contract) ERR_SHIPMENT_ALREADY_EXISTS)
        (asserts! (>= shipment-value MIN_SHIPMENT_VALUE) ERR_INVALID_AMOUNT)
        (asserts! (validate-delivery-parties tx-sender carrier receiver) ERR_INVALID_PARTIES)
        (asserts! (<= expected-delivery-blocks MAX_DELIVERY_DELAY) ERR_INVALID_AMOUNT)
        
        ;; Transfer escrow amount (simplified - in production would use proper escrow)
        ;; (try! (stx-transfer? total-escrow tx-sender (as-contract tx-sender)))
        
        ;; Create shipping contract
        (map-set shipping-contracts
            {shipment-id: shipment-id}
            {
                shipper: tx-sender,
                carrier: carrier,
                receiver: receiver,
                container-id: container-id,
                origin-port: origin-port,
                destination-port: destination-port,
                cargo-description: cargo-description,
                total-value: shipment-value,
                escrow-amount: total-escrow,
                expected-delivery: (+ stacks-block-height expected-delivery-blocks),
                created-at: stacks-block-height,
                status: "active",
                is-insured: is-insured
            }
        )
        
        ;; Initialize payment escrow tracking
        (map-set payment-escrow
            {shipment-id: shipment-id}
            {
                total-amount: total-escrow,
                carrier-payment: shipment-value,
                platform-fee: platform-fee,
                insurance-fee: insurance-fee,
                penalty-deductions: u0,
                final-amount: shipment-value,
                is-released: false,
                released-at: u0
            }
        )
        
        ;; Set default delivery conditions
        (map-set delivery-conditions
            {shipment-id: shipment-id}
            {
                temperature-min: 0,    ;; 0C
                temperature-max: 2500, ;; 25C
                humidity-max: u8000,   ;; 80%
                shock-max: u200,       ;; 2G
                delivery-window-start: (+ stacks-block-height expected-delivery-blocks),
                delivery-window-end: (+ stacks-block-height expected-delivery-blocks u144), ;; +1 day grace
                special-handling: "",
                documentation-required: (list)
            }
        )
        
        (var-set total-shipments (+ (var-get total-shipments) u1))
        (var-set total-escrow-amount (+ (var-get total-escrow-amount) total-escrow))
        
        (ok shipment-id)
    )
)

;; Confirm delivery by authorized parties
(define-public (confirm-delivery
    (shipment-id (string-ascii 64))
    (confirmation-type (string-ascii 30))
    (signature-hash (buff 64))
    (notes (string-ascii 300))
    (condition-rating uint)
    (evidence-hash (buff 32))
)
    (let (
        (contract-info (map-get? shipping-contracts {shipment-id: shipment-id}))
        (existing-confirmation (map-get? delivery-confirmations {shipment-id: shipment-id, confirmer: tx-sender}))
    )
        (asserts! (is-some contract-info) ERR_NOT_FOUND)
        (asserts! (is-none existing-confirmation) ERR_ALREADY_CONFIRMED)
        (asserts! (<= condition-rating u100) ERR_INVALID_AMOUNT)
        
        (match contract-info
            contract
                (begin
                    (asserts! (is-eq (get status contract) "active") ERR_SHIPMENT_NOT_ACTIVE)
                    (asserts! (or 
                        (is-eq tx-sender (get shipper contract))
                        (is-eq tx-sender (get carrier contract))
                        (is-eq tx-sender (get receiver contract))
                    ) ERR_UNAUTHORIZED)
                    
                    ;; Record delivery confirmation
                    (map-set delivery-confirmations
                        {shipment-id: shipment-id, confirmer: tx-sender}
                        {
                            confirmation-type: confirmation-type,
                            confirmed-at: stacks-block-height,
                            signature-hash: signature-hash,
                            notes: notes,
                            condition-rating: condition-rating,
                            photographic-evidence: evidence-hash
                        }
                    )
                    
                    ;; Check if all parties have confirmed
                    (if (check-all-confirmations shipment-id)
                        (begin
                            (update-shipment-status shipment-id "delivered")
                            (try! (process-automatic-payment shipment-id))
                            (var-set completed-deliveries (+ (var-get completed-deliveries) u1))
                            (ok "delivery-completed")
                        )
                        (ok "confirmation-recorded")
                    )
                )
            ERR_NOT_FOUND
        )
    )
)

;; Record condition violations
(define-public (record-condition-violation
    (shipment-id (string-ascii 64))
    (violation-type (string-ascii 50))
    (severity-level uint)
    (measured-value int)
    (threshold-value int)
)
    (let (
        (contract-info (map-get? shipping-contracts {shipment-id: shipment-id}))
        (violation-id (var-get next-violation-id))
    )
        (asserts! (is-some contract-info) ERR_NOT_FOUND)
        (asserts! (<= severity-level u5) ERR_INVALID_AMOUNT)
        
        (match contract-info
            contract
                (begin
                    (asserts! (is-eq (get status contract) "active") ERR_SHIPMENT_NOT_ACTIVE)
                    
                    (let (
                        (penalty-amount (calculate-condition-penalty u1 (get total-value contract)))
                    )
                        ;; Record the violation
                        (map-set condition-violations
                            {shipment-id: shipment-id, violation-id: violation-id}
                            {
                                violation-type: violation-type,
                                detected-at: stacks-block-height,
                                severity-level: severity-level,
                                measured-value: measured-value,
                                threshold-value: threshold-value,
                                penalty-amount: penalty-amount,
                                is-disputed: false
                            }
                        )
                        
                        ;; Update escrow with penalty
                        (match (map-get? payment-escrow {shipment-id: shipment-id})
                            escrow
                                (map-set payment-escrow
                                    {shipment-id: shipment-id}
                                    (merge escrow {
                                        penalty-deductions: (+ (get penalty-deductions escrow) penalty-amount),
                                        final-amount: (- (get carrier-payment escrow) penalty-amount)
                                    })
                                )
                            false
                        )
                        
                        (var-set next-violation-id (+ violation-id u1))
                        (var-set total-penalties (+ (var-get total-penalties) penalty-amount))
                        
                        (ok violation-id)
                    )
                )
            ERR_NOT_FOUND
        )
    )
)

;; Process automatic payment upon successful delivery
(define-public (process-automatic-payment (shipment-id (string-ascii 64)))
    (let (
        (contract-info (map-get? shipping-contracts {shipment-id: shipment-id}))
        (escrow-info (map-get? payment-escrow {shipment-id: shipment-id}))
    )
        (asserts! (is-some contract-info) ERR_NOT_FOUND)
        (asserts! (is-some escrow-info) ERR_NOT_FOUND)
        
        (match contract-info contract-data
            (match escrow-info escrow-data
                (begin
                    (asserts! (is-eq (get status contract-data) "delivered") ERR_SHIPMENT_NOT_ACTIVE)
                    (asserts! (not (get is-released escrow-data)) ERR_ALREADY_CONFIRMED)
                    
                    ;; Mark payment as released
                    (map-set payment-escrow
                        {shipment-id: shipment-id}
                        (merge escrow-data {
                            is-released: true,
                            released-at: stacks-block-height
                        })
                    )
                    
                    ;; Transfer payments (simplified)
                    ;; (try! (as-contract (stx-transfer? (get final-amount escrow-data) tx-sender (get carrier contract-data))))
                    ;; (try! (as-contract (stx-transfer? (get platform-fee escrow-data) tx-sender CONTRACT_OWNER)))
                    
                    (ok (get final-amount escrow-data))
                )
                ERR_NOT_FOUND
            )
            ERR_NOT_FOUND
        )
    )
)

;; Initiate dispute resolution
(define-public (initiate-dispute
    (shipment-id (string-ascii 64))
    (dispute-reason (string-ascii 200))
    (arbitrator principal)
)
    (let (
        (contract-info (map-get? shipping-contracts {shipment-id: shipment-id}))
        (existing-dispute (map-get? dispute-records {shipment-id: shipment-id}))
    )
        (asserts! (is-some contract-info) ERR_NOT_FOUND)
        (asserts! (is-none existing-dispute) ERR_DISPUTE_ACTIVE)
        
        (match contract-info
            contract
                (begin
                    (asserts! (or 
                        (is-eq tx-sender (get shipper contract))
                        (is-eq tx-sender (get carrier contract))
                        (is-eq tx-sender (get receiver contract))
                    ) ERR_UNAUTHORIZED)
                    
                    (map-set dispute-records
                        {shipment-id: shipment-id}
                        {
                            initiated-by: tx-sender,
                            dispute-reason: dispute-reason,
                            created-at: stacks-block-height,
                            resolution-deadline: (+ stacks-block-height DISPUTE_RESOLUTION_PERIOD),
                            arbitrator: arbitrator,
                            status: "pending",
                            resolution: "",
                            resolved-at: u0
                        }
                    )
                    
                    (update-shipment-status shipment-id "disputed")
                    
                    (ok true)
                )
            ERR_NOT_FOUND
        )
    )
)

;; Read-only functions
(define-read-only (get-shipping-contract (shipment-id (string-ascii 64)))
    (map-get? shipping-contracts {shipment-id: shipment-id})
)

(define-read-only (get-delivery-conditions (shipment-id (string-ascii 64)))
    (map-get? delivery-conditions {shipment-id: shipment-id})
)

(define-read-only (get-delivery-confirmation (shipment-id (string-ascii 64)) (confirmer principal))
    (map-get? delivery-confirmations {shipment-id: shipment-id, confirmer: confirmer})
)

(define-read-only (get-payment-escrow (shipment-id (string-ascii 64)))
    (map-get? payment-escrow {shipment-id: shipment-id})
)

(define-read-only (get-condition-violation (shipment-id (string-ascii 64)) (violation-id uint))
    (map-get? condition-violations {shipment-id: shipment-id, violation-id: violation-id})
)

(define-read-only (get-dispute-record (shipment-id (string-ascii 64)))
    (map-get? dispute-records {shipment-id: shipment-id})
)

(define-read-only (get-platform-statistics)
    {
        total-shipments: (var-get total-shipments),
        completed-deliveries: (var-get completed-deliveries),
        total-escrow: (var-get total-escrow-amount),
        total-penalties: (var-get total-penalties),
        success-rate: (if (> (var-get total-shipments) u0)
            (/ (* (var-get completed-deliveries) u100) (var-get total-shipments))
            u0)
    }
)

;; title: automated-delivery-verification
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

