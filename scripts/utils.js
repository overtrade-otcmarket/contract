import { Contract } from 'starknet';

async function getContract(provider, contract_address, account = null) {
    const { abi: contract_abi } = await provider.getClassAt(contract_address);
    if (!contract_abi) {
        throw new Error("Contract not found");
    }
    const contract = new Contract(contract_abi, contract_address, provider);
    if (account) {
        contract.connect(account);
    }
    return contract;
}

export { getContract };