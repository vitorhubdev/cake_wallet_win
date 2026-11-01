import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_evm/evm_chain_exceptions.dart';

/// A symbol is a display name, not an ERC20 identifier. Never resolve a token
/// transfer or approval by symbol when another contract can use the same name.
CryptoCurrency resolveEvmTransactionCurrency(
    Iterable<CryptoCurrency> available, CryptoCurrency requested, int chainId) {
  if (chainId <= 0) throw ArgumentError.value(chainId, 'chainId');
  if (requested is Erc20Token) {
    final address = requested.contractAddress.toLowerCase();
    if (!RegExp(r'^0x[0-9a-f]{40}$').hasMatch(address) ||
        (requested.chainId != null && requested.chainId != chainId)) {
      throw EVMChainTransactionCreationException.fromMessage(
          'The requested token does not belong to the selected network.');
    }
    final matches = available.whereType<Erc20Token>().where((token) =>
        token.contractAddress.toLowerCase() == address &&
        (token.chainId == null || token.chainId == chainId)).toList();
    if (matches.length != 1 || matches.single.decimals != requested.decimals) {
      throw EVMChainTransactionCreationException.fromMessage(
          'The token contract or decimals are missing or ambiguous. Refresh the token before sending.');
    }
    return matches.single;
  }
  final matches = available.where((coin) => coin is! Erc20Token &&
      coin.title == requested.title &&
      (coin.tag == requested.tag || coin.tag == requested.title)).toList();
  if (matches.length != 1) {
    throw EVMChainTransactionCreationException.fromMessage(
        'The requested currency is not available on the selected network.');
  }
  return matches.single;
}
