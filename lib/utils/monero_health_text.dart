import 'package:cw_core/monero_node_health.dart';

String moneroHealthTitle(MoneroNodeHealth health, {required bool portuguese}) {
  final pt = portuguese;
  return switch (health.state) {
    MoneroNodeState.ready => pt ? 'Nó pronto' : 'Node ready',
    MoneroNodeState.syncing => pt ? 'Nó ainda sincronizando' : 'Node still synchronizing',
    MoneroNodeState.offline => pt ? 'Nó informa estar offline' : 'Node reports offline',
    MoneroNodeState.unknownReadiness =>
      pt ? 'RPC responde; estado incompleto' : 'RPC responds; readiness unknown',
    MoneroNodeState.wrongNetwork => pt ? 'Rede Monero incorreta' : 'Wrong Monero network',
    MoneroNodeState.authenticationRequired =>
      pt ? 'Autenticação necessária ou recusada' : 'Authentication required or rejected',
    MoneroNodeState.forbidden => pt ? 'Acesso negado' : 'Access denied',
    MoneroNodeState.rateLimited => pt ? 'Limite de requisições' : 'Rate limited',
    MoneroNodeState.serverError => pt ? 'Erro do servidor' : 'Server error',
    MoneroNodeState.rpcError => pt ? 'Erro RPC' : 'RPC error',
    MoneroNodeState.invalidResponse => pt ? 'Resposta RPC inválida' : 'Invalid RPC response',
    MoneroNodeState.redirect => pt ? 'Redirecionamento não seguido' : 'Redirect not followed',
    MoneroNodeState.tlsError => pt ? 'Falha de certificado/TLS' : 'Certificate/TLS failure',
    MoneroNodeState.dnsFailure => pt ? 'Falha ao resolver o servidor' : 'Server name lookup failed',
    MoneroNodeState.connectionRefused => pt ? 'Conexão TCP recusada' : 'TCP connection refused',
    MoneroNodeState.networkFailure =>
      pt ? 'Conexão interrompida ou sem rota' : 'Connection interrupted or no route',
    MoneroNodeState.timeout => pt ? 'Tempo de resposta esgotado' : 'Response deadline exceeded',
    MoneroNodeState.proxyUnavailable => pt ? 'Proxy/Tor indisponível' : 'Proxy/Tor unavailable',
    MoneroNodeState.invalidConfig => pt ? 'Configuração inválida' : 'Invalid configuration',
  };
}

String moneroHealthDetail(MoneroNodeHealth health, {required bool portuguese}) {
  final details = <String>[];
  final pt = portuguese;
  if (health.latencyMs != null) {
    details.add('${pt ? 'Latência RPC' : 'RPC latency'}: ${health.latencyMs} ms');
    if (health.samples > 1) {
      details.add('${pt ? 'mediana de' : 'median of'} ${health.samples}');
      details.add('${pt ? 'variação' : 'range'}: ${health.jitterMs ?? 0} ms');
    }
  }
  if (health.httpStatus != null && health.httpStatus != 200)
    details.add('HTTP ${health.httpStatus}');
  if (health.height != null)
    details.add('${pt ? 'altura informada' : 'reported height'}: ${health.height}');
  if (health.viaProxy) details.add(pt ? 'via proxy/Tor' : 'via proxy/Tor');
  if (health.bootstrap) details.add(pt ? 'resposta via bootstrap' : 'bootstrap response');
  if (health.retryAfter != null) {
    final left = health.checkedAt.add(health.retryAfter!).difference(DateTime.now()).inSeconds;
    if (left > 0) details.add('${pt ? 'aguarde' : 'wait'} ${left}s');
  }
  if (health.state == MoneroNodeState.forbidden ||
      health.state == MoneroNodeState.connectionRefused) {
    details.add(pt ? 'Não confirma bloqueio do seu IP.' : 'This does not confirm an IP ban.');
  }
  if (health.state == MoneroNodeState.tlsError) {
    details.add(
      pt
          ? 'Confira endereço, certificado e relógio do sistema.'
          : 'Check the address, certificate and system clock.',
    );
  }
  if (!health.fresh)
    details.add(pt ? 'Medição antiga; teste novamente.' : 'Old measurement; test again.');
  return details.join(' · ');
}
