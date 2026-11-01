import hashlib,pathlib
p=pathlib.Path('cw_evm/lib/evm_chain_wallet.dart')
assert hashlib.sha256(p.read_bytes()).hexdigest()=='001dbe526858dc09ef363670526b200f9bb7075013a6c221e310028a9ba26054'
s=p.read_text()
def replace(text,old,new):
    if text.count(old)!=1: raise RuntimeError('Expected one source context: '+old[:90])
    return text.replace(old,new)
s=replace(s,"import 'package:cw_evm/utils/network_chain_utils.dart';", "import 'package:cw_evm/utils/network_chain_utils.dart';\nimport 'package:cw_evm/utils/transaction_currency.dart';")
a=s.index('  Future<PendingTransaction> createTransaction(Object credentials) async {')
b=s.index('  Future<PendingTransaction> createCallDataTransaction(',a)
t=s[a:b]
t=replace(t, '    final hasMultiDestination = outputs.length > 1;', '''    final generation = _connectionGeneration;
    final signingClient = _client;
    final signingChain = selectedChainId;
    _requireTransactionSession(generation, signingClient);
    if (!outputs.single.sendAll && outputs.single.cryptoAmount.isNegative) {
      throw EVMChainTransactionCreationException.fromMessage('A transfer amount cannot be negative.');
    }
    final hasMultiDestination = outputs.length > 1;''')
a1=t.index('    final String? opReturnMemo = outputs.first.memo;')
b1=t.index('    final currencyBalance = balance[transactionCurrency]!;',a1)
t=t[:a1]+'''    final memo = outputs.single.memo;
    final memoBytes = memo == null ? null : Uint8List.fromList(utf8.encode(memo));
    final hexOpReturnMemo = memoBytes == null ? null : '0x${HEX.encode(memoBytes)}';
    final transactionCurrency = resolveEvmTransactionCurrency(
        balance.keys, _credentials.currency, signingChain);

'''+t[b1:]
old='''        contractAddress: contractAddress,
      );

      estimatedFeesForTransaction ='''
new='''        contractAddress: contractAddress,
        data: memoBytes,
      );
      _requireTransactionSession(generation, signingClient);

      estimatedFeesForTransaction ='''
assert t.count(old)==2
t=t.replace(old,new)
t=t.replace('if (selectedChainId == 8453)', 'if (signingChain == 8453)')
t=t.replace('provideERC20Info(transactionCurrency.contractAddress, selectedChainId)', 'provideERC20Info(transactionCurrency.contractAddress, signingChain)')
t=replace(t,'    final pendingEVMChainTransaction = await _client.signTransaction(','''    _requireTransactionSession(generation, signingClient);
    final pendingEVMChainTransaction = await signingClient.signTransaction(''')
t=t.replace('EVMChainUtils.getFeeCurrency(selectedChainId)','EVMChainUtils.getFeeCurrency(signingChain)')
t=replace(t,'    return pendingEVMChainTransaction;', '''    _requireTransactionSession(generation, signingClient);
    return pendingEVMChainTransaction;''')
s=s[:a]+t+s[b:]
a=s.index('  Future<PendingTransaction> createCallDataTransaction(')
b=s.index('  Future<PendingTransaction> createApprovalTransaction(',a)
t=s[a:b]
t=replace(t,'    // Define Native Currency', '''    final generation = _connectionGeneration;
    final signingClient = _client;
    _requireTransactionSession(generation, signingClient);
    // Define Native Currency''')
t=replace(t,'    final nativeBal = balance[nativeCurrency]?.available', '''    _requireTransactionSession(generation, signingClient);
    final nativeBal = balance[nativeCurrency]?.available''')
t=replace(t,'      return _client.signTransaction(', '      final pending = await signingClient.signTransaction(')
t=replace(t,'''        useBlinkProtection: useBlinkProtection,
      );
    } catch (_) {''','''        useBlinkProtection: useBlinkProtection,
      );
      _requireTransactionSession(generation, signingClient);
      return pending;
    } catch (_) {''')
s=s[:a]+t+s[b:]
a=s.index('  Future<PendingTransaction> createApprovalTransaction(')
b=s.index('  Future<void> _updateTransactions()',a)
t=s[a:b]
t=replace(t,'''    final transactionCurrency =
        balance.keys.firstWhere((element) => element.symbol == amount.currency.symbol);
    assert(transactionCurrency is Erc20Token);''','''    final generation = _connectionGeneration;
    final signingClient = _client;
    _requireTransactionSession(generation, signingClient);
    if (amount.currency is! Erc20Token || amount.isNegative) {
      throw EVMChainTransactionCreationException.fromMessage('An approval requires an ERC20 token and a non-negative amount.');
    }
    final transactionCurrency = resolveEvmTransactionCurrency(
        balance.keys, amount.currency as Erc20Token, selectedChainId) as Erc20Token;''')
t=t.replace('(transactionCurrency as Erc20Token).contractAddress','transactionCurrency.contractAddress')
t=replace(t,'    final int safeGasUnits = gasFeesModel.estimatedGasUnits == 0','''    _requireTransactionSession(generation, signingClient);
    final int safeGasUnits = gasFeesModel.estimatedGasUnits == 0''')
t=replace(t,'    return _client.signApprovalTransaction(', '    final pending = await signingClient.signApprovalTransaction(')
t=replace(t,'''      useBlinkProtection: useBlinkProtection,
    );
  }
''','''      useBlinkProtection: useBlinkProtection,
    );
    _requireTransactionSession(generation, signingClient);
    return pending;
  }
''')
s=s[:a]+t+s[b:]
s=replace(s,'  bool _sessionCurrent(int generation, EVMChainClient client) =>', '''  void _requireTransactionSession(int generation, EVMChainClient client) {
    if (!_sessionCurrent(generation, client)) {
      throw EVMChainTransactionCreationException.fromMessage(
          'The wallet network or connection changed while preparing the transaction. Review it again.');
    }
  }

  bool _sessionCurrent(int generation, EVMChainClient client) =>''')
p.write_text(s)
print('Applied contract-identity, UTF-8 memo and transaction-session guards.')
