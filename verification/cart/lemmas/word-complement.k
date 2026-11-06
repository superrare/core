module CART-WORD-COMPLEMENT
    imports KONTROL-MAIN

    // Trusted semantic rewrite, separately checked against 257-bit unsigned arithmetic.
    // Both range guards are required to identify K's arbitrary-precision xor with a 256-bit word.
    rule X:Int xorInt maxUInt256 => maxUInt256 -Int X
      requires 0 <=Int X andBool X <Int pow256
      [simplification]
endmodule
