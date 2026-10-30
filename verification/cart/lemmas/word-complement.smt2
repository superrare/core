(set-option :timeout 30000)
(set-logic QF_BV)
(declare-const word (_ BitVec 256))
; Two zero-extended unsigned 256-bit values cannot overflow a 257-bit sum.
; Expected sum is 2^256 - 1, represented as a zero-extended 256-bit all-ones word.
(assert (not (= (bvadd ((_ zero_extend 1) word)
                      ((_ zero_extend 1) (bvxor word #xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)))
                ((_ zero_extend 1) #xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff))))
(check-sat)
