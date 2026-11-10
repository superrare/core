module CART-WORD-ARITHMETIC
    imports KONTROL-MAIN

    // Legacy complement identity, copied unchanged from the approved historical helper.
    // Both range guards are required for the correspondence with unsigned 256-bit words.
    rule X:Int xorInt maxUInt256 => maxUInt256 -Int X
      requires 0 <=Int X andBool X <Int pow256
      [simplification]

    // K defines chop(I) as I modInt 2^256. Two word-sized integers differ by strictly
    // less than 2^256, so their difference is zero modulo 2^256 iff they are equal.
    // These are trusted semantic rewrites with a separately solver-checked arithmetic
    // justification, not kernel certificates. Restrict matching to Keccak values so the
    // stock hash-bound rules discharge the guards without probing unrelated arithmetic.
    rule 0 ==Int chop(keccak(B1:Bytes) -Int keccak(B2:Bytes)) => keccak(B1) ==Int keccak(B2)
      requires 0 <=Int keccak(B1) andBool keccak(B1) <Int pow256 andBool 0 <=Int keccak(B2) andBool keccak(B2) <Int pow256
      [simplification]

    rule chop(keccak(B1:Bytes) -Int keccak(B2:Bytes)) ==Int 0 => keccak(B1) ==Int keccak(B2)
      requires 0 <=Int keccak(B1) andBool keccak(B1) <Int pow256 andBool 0 <=Int keccak(B2) andBool keccak(B2) <Int pow256
      [simplification]
endmodule
