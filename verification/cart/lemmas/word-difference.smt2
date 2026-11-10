(set-option :timeout 30000)
(set-logic QF_LIA)
(declare-const x Int)
(declare-const y Int)
(define-fun modulus () Int 115792089237316195423570985008687907853269984665640564039457584007913129639936)
; K chop is Euclidean remainder modulo 2^256. Both operands must be word-sized.
(assert (and (<= 0 x) (< x modulus) (<= 0 y) (< y modulus)))
; Negate the equivalence. UNSAT checks both zero-comparison orientations.
(assert (not (= (= 0 (mod (- x y) modulus)) (= x y))))
(check-sat)
