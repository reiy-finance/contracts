// Copyright (c) Reiy Finance
module reiy::types;

use std::type_name::{Self, TypeName};

/// Directed trading pair `(sell -> buy)`. SUI->USDC is distinct from USDC->SUI.
/// * `sell` - The fully-qualified type of the token being sold
/// * `buy`  - The fully-qualified type of the token being bought
public struct PairKey has copy, drop, store {
    sell: TypeName,
    buy: TypeName,
}

public fun pair_key<Sell, Buy>(): PairKey {
    PairKey { sell: type_name::with_defining_ids<Sell>(), buy: type_name::with_defining_ids<Buy>() }
}

public fun new_pair_key(sell: TypeName, buy: TypeName): PairKey {
    PairKey { sell, buy }
}

public fun sell_type(self: &PairKey): TypeName { self.sell }

public fun buy_type(self: &PairKey): TypeName { self.buy }

/// The opposing pair `(buy -> sell)`.
public fun reverse(self: &PairKey): PairKey {
    PairKey { sell: self.buy, buy: self.sell }
}
