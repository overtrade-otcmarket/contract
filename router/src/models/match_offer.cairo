use starknet::ContractAddress;
use core::option::OptionTrait;
use core::hash::{HashStateTrait, HashStateExTrait, Hash};
use pedersen::PedersenTrait;
use ecdsa::check_ecdsa_signature;

const ADDRESS_SIGN: felt252 = 'a';
const PUBLIC_KEY_SIGN: felt252 = 'b';
const STARKNET_DOMAIN_TYPE_HASH: felt252 =
    selector!("StarkNetDomain(name:felt,version:felt,chainId:felt)");
const MATCH_OFFER_INFO_TYPE_HASH: felt252 =
    selector!("MatchOfferInfo(offer_id:felt,offer_token:felt,match_amount:felt,market_price:felt,nonce:felt)");

#[derive(Copy, Drop, Serde, PartialEq, Hash)]
struct StarknetDomain {
    name: felt252,
    version: felt252,
    chain_id: felt252,
}

#[derive(Copy, Drop, Serde, PartialEq, Hash)]
struct MatchOffer {
    offer_id: u256,
    offer_token: ContractAddress,
    match_amount: u256,
    market_price: u256,
    nonce: u256,
}

#[derive(Copy, Drop, Serde, PartialEq, Hash)]
struct MatchOfferInfo {
    offer_id: felt252,
    offer_token: felt252,
    match_amount: felt252,
    market_price: felt252,
    nonce: felt252,
}

trait IStructHash<T> {
    fn hash_struct(self: @T) -> felt252;
}

trait IOffchainMessageHash<T> {
    fn get_message_hash(self: @T) -> felt252;
}

trait MatchOfferInfoTrait {
    fn verify_signature(match_offer_info: MatchOfferInfo, signature_r: felt252, signature_s: felt252) -> MatchOffer;
}

impl MatchOfferInfoImpl of MatchOfferInfoTrait {
    fn verify_signature(match_offer_info: MatchOfferInfo, signature_r: felt252, signature_s: felt252) -> MatchOffer {
        let message_hash = match_offer_info.get_message_hash();
        assert(
            check_ecdsa_signature(
                message_hash,
                PUBLIC_KEY_SIGN,
                signature_r,
                signature_s
            ),
            'Invalid signature'
        );
        MatchOffer {
            offer_id: match_offer_info.offer_id.try_into().unwrap(),
            offer_token: match_offer_info.offer_token.try_into().unwrap(),
            match_amount: match_offer_info.match_amount.try_into().unwrap(),
            market_price: match_offer_info.market_price.try_into().unwrap(),
            nonce: match_offer_info.nonce.try_into().unwrap(),
        }
    }
}

impl OffchainMessageHashMatchOfferInfo of IOffchainMessageHash<MatchOfferInfo> {
    fn get_message_hash(self: @MatchOfferInfo) -> felt252 {
        let domain = StarknetDomain { name: 'STARKNET', version: 1, chain_id: 'SN_MAIN' };
        let address_sign: ContractAddress = ADDRESS_SIGN.try_into().unwrap();
        let mut hashState = PedersenTrait::new(0);
        hashState = hashState.update_with('StarkNet Message');
        hashState = hashState.update_with(domain.hash_struct());
        hashState = hashState.update_with(address_sign);
        hashState = hashState.update_with(self.hash_struct());
        hashState = hashState.update_with(4);
        hashState.finalize()
    }
}

impl StructHashStarknetDomain of IStructHash<StarknetDomain> {
    fn hash_struct(self: @StarknetDomain) -> felt252 {
        let mut hashState = PedersenTrait::new(0);
        hashState = hashState.update_with(STARKNET_DOMAIN_TYPE_HASH);
        hashState = hashState.update_with(*self);
        hashState = hashState.update_with(4);
        hashState.finalize()
    }
}

impl StructHashMatchOfferInfo of IStructHash<MatchOfferInfo> {
    fn hash_struct(self: @MatchOfferInfo) -> felt252 {
        let mut hashState = PedersenTrait::new(0);
        hashState = hashState.update_with(MATCH_OFFER_INFO_TYPE_HASH);
        hashState = hashState.update_with(*self);
        hashState = hashState.update_with(6);
        hashState.finalize()
    }
}