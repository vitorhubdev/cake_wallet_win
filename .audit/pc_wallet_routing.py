import hashlib,pathlib
root=pathlib.Path('.')

def replace(text, old, new):
    if text.count(old)!=1: raise RuntimeError('Source context must match exactly once: '+old[:65])
    return text.replace(old,new)

p=root/'cw_evm/lib/evm_chain_wallet.dart'
assert hashlib.sha256(p.read_bytes()).hexdigest()=='bf1034ad6cab5e549d28c3ee4c0bcbb8aef65b43ff4813b109c608d0b2874a59'
s=p.read_text()
s=replace(s, '    selectedChainId = chainId;\n    _client = EVMChainClientFactory.createClient(selectedChainId);', '    selectedChainId = chainId;\n    (walletAddresses as EVMChainWalletAddresses).setChainId(chainId);\n    _client = EVMChainClientFactory.createClient(selectedChainId);')
s=replace(s, '      if (!correctChain) {\n        throw ConnectionException(', '      if (!correctChain) {\n        client.stop(); // A wrong-chain RPC must not remain available for sending.\n        throw ConnectionException(')
s=replace(s, '    final outputs = _credentials.outputs;\n    final hasMultiDestination = outputs.length > 1;', '''    final outputs = _credentials.outputs;
    if (outputs.length != 1) {
      throw EVMChainTransactionCreationException.fromMessage(
          'An EVM transfer requires exactly one recipient. Batch transfers are not supported.');
    }
    final hasMultiDestination = outputs.length > 1;''')
p.write_text(s)
p=root/'cw_evm/lib/evm_chain_wallet_addresses.dart'
assert hashlib.sha256(p.read_bytes()).hexdigest()=='ffcd04fc00110cad7c2255a8202bc78aee4e05b58f05fc1a510d2c4154ff3eee'
s=p.read_text()
s=replace(s,'  final int _selectedChainId;','''  @observable
  int _selectedChainId;

  @action
  void setChainId(int chainId) {
    if (chainId <= 0) throw ArgumentError.value(chainId, 'chainId');
    _selectedChainId = chainId;
  }''')
p.write_text(s)
print('Applied exact recipient, payment URI and wrong-chain connection guards.')
