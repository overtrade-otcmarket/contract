use starknet::ContractAddress;

#[starknet::interface]
pub trait IOwnable<TContractState> {
    fn owner(self: @TContractState) -> ContractAddress;
    fn dev(self: @TContractState) -> ContractAddress;
    fn transfer_owner(ref self: TContractState, new_owner: ContractAddress);
    fn transfer_dev(ref self: TContractState, new_dev: ContractAddress);
}

#[starknet::component]
pub mod OwnableComponent {

    use starknet::{ContractAddress, get_caller_address};
    
    pub mod Errors {
        pub const UNAUTHORIZED: felt252 = 'Not owner';
        pub const ZERO_ADDRESS_OWNER: felt252 = 'Owner cannot be zero';
        pub const ZERO_ADDRESS_CALLER: felt252 = 'Caller cannot be zero';
    }

    #[storage]
    struct Storage {
        pub owner: ContractAddress,
        pub dev: ContractAddress,
    }

    #[derive(Drop, Debug, PartialEq, starknet::Event)]
    pub struct OwnerTransferredEvent {
        pub previous: ContractAddress,
        pub new: ContractAddress
    }

    #[derive(Drop, Debug, PartialEq, starknet::Event)]
    pub struct DevTransferredEvent {
        pub previous: ContractAddress,
        pub new: ContractAddress
    }


    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        OwnerTransferredEvent: OwnerTransferredEvent,
        DevTransferredEvent: DevTransferredEvent
    }

    #[embeddable_as(OwnableImpl)]
    pub impl Ownable<
        TContractState, +HasComponent<TContractState>
    > of super::IOwnable<ComponentState<TContractState>> {
        fn owner(self: @ComponentState<TContractState>) -> ContractAddress {
            self.owner.read()
        }

        fn dev(self: @ComponentState<TContractState>) -> ContractAddress {
            self.dev.read()
        }

        fn transfer_owner(ref self: ComponentState<TContractState>, new_owner: ContractAddress) {
            self._assert_only_owner();
            self._transfer_owner(new_owner);
        }

        fn transfer_dev(ref self: ComponentState<TContractState>, new_dev: ContractAddress) {
            self._assert_only_owner();
            self._transfer_dev(new_dev);
        }
    }

    #[generate_trait]
    pub impl OwnableInternalImpl<
        TContractState, +HasComponent<TContractState>
    > of OwnableInternalTrait<TContractState> {

        fn initializer(ref self: ComponentState<TContractState>, owner: ContractAddress, dev: ContractAddress) {
            assert(owner.is_non_zero(), Errors::ZERO_ADDRESS_OWNER);
            self.owner.write(owner);
            self.dev.write(dev);
        }

        fn _assert_only_admin(self: @ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert(caller.is_non_zero(), Errors::ZERO_ADDRESS_CALLER);
            assert((caller == self.dev.read() || caller == self.owner.read()), Errors::UNAUTHORIZED);
        }

        fn _assert_only_owner(self: @ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert(caller.is_non_zero(), Errors::ZERO_ADDRESS_CALLER);
            assert(caller == self.owner.read(), Errors::UNAUTHORIZED);
        }

        fn _transfer_owner(ref self: ComponentState<TContractState>, new: ContractAddress) {
            assert(new.is_non_zero(), Errors::ZERO_ADDRESS_OWNER);
            let previous = self.owner.read();
            self.owner.write(new);
            self
                .emit(
                    Event::OwnerTransferredEvent(OwnerTransferredEvent { previous, new })
                );
        }

        fn _transfer_dev(ref self: ComponentState<TContractState>, new: ContractAddress) {
            assert(new.is_non_zero(), Errors::ZERO_ADDRESS_OWNER);
            let previous = self.dev.read();
            self.dev.write(new);
            self
                .emit(
                    Event::DevTransferredEvent(DevTransferredEvent { previous, new })
                );
        }
    }
}