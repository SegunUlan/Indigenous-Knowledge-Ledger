(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-CONTRIBUTION (err u101))
(define-constant ERR-ALREADY-VOTED (err u102))
(define-constant ERR-CONTRIBUTION-NOT-FOUND (err u103))
(define-constant ERR-INSUFFICIENT-TOKENS (err u104))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u105))
(define-constant ERR-KNOWLEDGE-NOT-LICENSED (err u106))

(define-fungible-token indigenous-token)

(define-non-fungible-token knowledge-nft uint)

(define-map contributions
    uint 
    {
        contributor: principal,
        title: (string-ascii 100),
        content: (string-utf8 1000),
        category: (string-ascii 50),
        votes: uint,
        verified: bool,
        timestamp: uint,
        royalty-percentage: uint,
        license-fee: uint,
        total-earnings: uint,
        access-count: uint
    }
)

(define-map contributor-stats
    principal
    {
        total-contributions: uint,
        reputation-score: uint,
        total-rewards: uint
    }
)

(define-map votes
    {contribution-id: uint, voter: principal}
    bool
)

(define-map knowledge-access
    {contribution-id: uint, accessor: principal}
    {
        access-timestamp: uint,
        payment-amount: uint
    }
)

(define-data-var contribution-counter uint u0)
(define-data-var token-per-contribution uint u100)
(define-data-var min-tokens-to-vote uint u10)

(define-public (initialize-contributor)
    (begin
        (map-set contributor-stats tx-sender {
            total-contributions: u0,
            reputation-score: u100,
            total-rewards: u0
        })
        (ok true)
    )
)

(define-public (submit-contribution (title (string-ascii 100)) (content (string-utf8 1000)) (category (string-ascii 50)) (royalty uint) (license-fee uint))
    (let 
        (
            (contribution-id (+ (var-get contribution-counter) u1))
            (contributor-data (default-to 
                {total-contributions: u0, reputation-score: u0, total-rewards: u0} 
                (map-get? contributor-stats tx-sender)
            ))
        )
        (asserts! (< royalty u100) ERR-INVALID-CONTRIBUTION)
        (try! (nft-mint? knowledge-nft contribution-id tx-sender))
        (try! (ft-mint? indigenous-token (var-get token-per-contribution) tx-sender))
        (map-set contributions contribution-id {
            contributor: tx-sender,
            title: title,
            content: content,
            category: category,
            votes: u0,
            verified: false,
            timestamp: burn-block-height,
            royalty-percentage: royalty,
            license-fee: license-fee,
            total-earnings: u0,
            access-count: u0
        })
        (map-set contributor-stats tx-sender {
            total-contributions: (+ (get total-contributions contributor-data) u1),
            reputation-score: (+ (get reputation-score contributor-data) u10),
            total-rewards: (+ (get total-rewards contributor-data) (var-get token-per-contribution))
        })
        (var-set contribution-counter contribution-id)
        (ok contribution-id)
    )
)

(define-public (vote-contribution (contribution-id uint))
    (let 
        (

            (contribution-data (unwrap! (map-get? contributions contribution-id) ERR-CONTRIBUTION-NOT-FOUND))
            (voter-balance (ft-get-balance indigenous-token tx-sender))
        )
        (asserts! (>= voter-balance (var-get min-tokens-to-vote)) ERR-INSUFFICIENT-TOKENS)
        (asserts! (is-none (map-get? votes {contribution-id: contribution-id, voter: tx-sender})) ERR-ALREADY-VOTED)
        (map-set votes {contribution-id: contribution-id, voter: tx-sender} true)
        (map-set contributions contribution-id 

            (merge contribution-data {votes: (+ (get votes contribution-data) u1)})
        )
        (ok true)
    )
)

(define-public (verify-contribution (contribution-id uint))
    (let 
        (
            (contribution (unwrap! (map-get? contributions contribution-id) ERR-CONTRIBUTION-NOT-FOUND))
        )

        (asserts! (is-eq tx-sender contract-caller) ERR-NOT-AUTHORIZED)
        (map-set contributions contribution-id 
            (merge contribution {verified: true})
        )
        (ok true)
    )
)

(define-read-only (get-contribution (contribution-id uint))
    (ok (map-get? contributions contribution-id))
)

(define-read-only (get-contributor-stats (contributor principal))
    (ok (map-get? contributor-stats contributor))
)

(define-public (license-knowledge (contribution-id uint))
    (let 
        (
            (contribution (unwrap! (map-get? contributions contribution-id) ERR-CONTRIBUTION-NOT-FOUND))
            (license-fee (get license-fee contribution))
            (contributor (get contributor contribution))
            (royalty-amount (/ (* license-fee (get royalty-percentage contribution)) u100))
            (platform-fee (- license-fee royalty-amount))
            (user-balance (ft-get-balance indigenous-token tx-sender))
        )
        (asserts! (>= user-balance license-fee) ERR-INSUFFICIENT-PAYMENT)
        (asserts! (> license-fee u0) ERR-KNOWLEDGE-NOT-LICENSED)
        (try! (ft-transfer? indigenous-token royalty-amount tx-sender contributor))
        (try! (ft-transfer? indigenous-token platform-fee tx-sender contract-caller))
        (map-set knowledge-access 
            {contribution-id: contribution-id, accessor: tx-sender}
            {
                access-timestamp: burn-block-height,
                payment-amount: license-fee
            }
        )
        (map-set contributions contribution-id 
            (merge contribution {
                total-earnings: (+ (get total-earnings contribution) license-fee),
                access-count: (+ (get access-count contribution) u1)
            })
        )
        (let 
            (
                (contributor-data (default-to 
                    {total-contributions: u0, reputation-score: u0, total-rewards: u0} 
                    (map-get? contributor-stats contributor)
                ))
            )
            (map-set contributor-stats contributor {
                total-contributions: (get total-contributions contributor-data),
                reputation-score: (+ (get reputation-score contributor-data) u5),
                total-rewards: (+ (get total-rewards contributor-data) royalty-amount)
            })
        )
        (ok true)
    )
)

(define-public (set-license-fee (contribution-id uint) (new-fee uint))
    (let 
        (
            (contribution (unwrap! (map-get? contributions contribution-id) ERR-CONTRIBUTION-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender (get contributor contribution)) ERR-NOT-AUTHORIZED)
        (map-set contributions contribution-id 
            (merge contribution {license-fee: new-fee})
        )
        (ok true)
    )
)

(define-read-only (get-access-history (contribution-id uint) (accessor principal))
    (ok (map-get? knowledge-access {contribution-id: contribution-id, accessor: accessor}))
)

(define-read-only (has-access (contribution-id uint) (accessor principal))
    (let 
        (
            (contribution (unwrap! (map-get? contributions contribution-id) ERR-CONTRIBUTION-NOT-FOUND))
            (access-record (map-get? knowledge-access {contribution-id: contribution-id, accessor: accessor}))
        )
        (ok (or 
            (is-eq accessor (get contributor contribution))
            (is-some access-record)
            (is-eq (get license-fee contribution) u0)
        ))
    )
)