import 'package:cw_core/utils/print_verbose.dart';
import 'package:cake_wallet/store/app_store.dart';

void Function()? _disposeCurrentNodeObserver;
void Function()? _disposePowNodeObserver;

void startOnCurrentNodeChangeReaction(AppStore appStore) {
  _disposeCurrentNodeObserver?.call();
  _disposePowNodeObserver?.call();
  _disposeCurrentNodeObserver = appStore.settingsStore.nodes.observe((change) async {
    try {
      final wallet = appStore.wallet;
      final node = change.newValue;
      if (wallet != null && node != null && node.type == wallet.type) {
        await wallet.connectToNode(node: node);
      }
    } catch (e) {
      printV(e.toString());
    }
  });
  _disposePowNodeObserver = appStore.settingsStore.powNodes.observe((change) async {
    try {
      final wallet = appStore.wallet;
      final node = change.newValue;
      if (wallet != null && node != null && node.type == wallet.type) {
        await wallet.connectToPowNode(node: node);
      }
    } catch (e) {
      printV(e.toString());
    }
  });
}
