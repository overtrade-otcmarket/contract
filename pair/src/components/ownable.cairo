use starknet::ContractAddress;

#[starknet::interface]
pub trait IOwnable<TContractState> {
    fn owner(self: @TContractState) -> ContractAddress;
    fn router(self: @TContractState) -> ContractAddress;
    fn dev(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
pub trait IRouter<TContractState> {
    fn owner(self: @TContractState) -> ContractAddress;
    fn router(self: @TContractState) -> ContractAddress;
    fn dev(self: @TContractState) -> ContractAddress;
}

#[starknet::component]
pub mod OwnableComponent {
    use starknet::{ContractAddress, get_caller_address};
    use super::{IRouterDispatcher, IRouterDispatcherTrait};
    pub mod Errors {
        pub const OWNER_UNAUTHORIZED: felt252 = 'Not owner';
        pub const ROUTER_UNAUTHORIZED: felt252 = 'Not router';
        pub const ADMIN_UNAUTHORIZED: felt252 = 'Not admin';
        pub const ZERO_ADDRESS_OWNER: felt252 = 'Owner cannot be zero';
        pub const ZERO_ADDRESS_CALLER: felt252 = 'Caller cannot be zero';
    }

    #[storage]
    struct Storage {
        pub router: ContractAddress,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct PairCreatedEvent {
        router: ContractAddress,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        PairCreatedEvent: PairCreatedEvent,
    }

    #[embeddable_as(OwnableImpl)]
    pub impl Ownable<
        TContractState, +HasComponent<TContractState>
    > of super::IOwnable<ComponentState<TContractState>> {
        fn router(self: @ComponentState<TContractState>) -> ContractAddress {
            self.router.read()
        }

        fn owner(self: @ComponentState<TContractState>) -> ContractAddress {
            IRouterDispatcher { contract_address: self.router.read() }.owner()
        }

        fn dev(self: @ComponentState<TContractState>) -> ContractAddress {
            IRouterDispatcher { contract_address: self.router.read() }.dev()
        }
    }

    #[generate_trait]
    pub impl OwnableInternalImpl<
        TContractState, +HasComponent<TContractState>
    > of OwnableInternalTrait<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>, router: ContractAddress) {
            assert(router.is_non_zero(), Errors::ZERO_ADDRESS_OWNER);
            self.router.write(router);
            self.emit(PairCreatedEvent { router });
        }

        fn _assert_only_owner(self: @ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert(caller.is_non_zero(), Errors::ZERO_ADDRESS_CALLER);
            let owner = IRouterDispatcher { contract_address: self.router.read() }.owner();
            assert(caller == owner, Errors::OWNER_UNAUTHORIZED);
        }

        fn _assert_only_admin(self: @ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert(caller.is_non_zero(), Errors::ZERO_ADDRESS_CALLER);
            let owner = IRouterDispatcher { contract_address: self.router.read() }.owner();
            let dev = IRouterDispatcher { contract_address: self.router.read() }.dev();
            assert((caller == owner || caller == dev), Errors::ADMIN_UNAUTHORIZED);
        }

        fn _assert_only_router(self: @ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert(caller.is_non_zero(), Errors::ZERO_ADDRESS_CALLER);
            assert(caller == self.router.read(), Errors::ROUTER_UNAUTHORIZED);
        }
    }
}
