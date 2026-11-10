# Cake Wallet PC — revisão e integração da v6.5.3

Registro de 8 de novembro de 2026. Candidato de código, não certificado de lançamento.

## Resultado e escopo

A comparação entre v6.5.2 e v6.5.3 contém 45 commits e 267 arquivos alterados
(7.708 inserções e 1.834 exclusões). O fork já continha 18 desses commits;
a integração incorpora os 27 restantes e preserva as correções específicas
Windows/Linux. Não se trata de trocar a etiqueta de binários antigos.

Base do fork: `1022d5751ca5813fbf6c8643ac775d789faf24d0`.
Upstream integrado: `d803aecf9de21461c7459c974ce5e3f2d92b70ed`.
Ancestral comum: `162a688d103a4f956ec0738f656f53df097db6dd`.

Houve três conflitos reais: transporte HTTP/IPv6, changelog do dashboard e
tradução PT-BR. Foram resolvidos pontualmente, sem substituir os arquivos
críticos do fork pelos do upstream. O inventário JSON registra todos os commits,
suas URLs, arquivos e a distinção entre já presentes e novos.

Não houve execução de 20 agentes de IA: não havia executor conectado para isso.
A revisão foi organizada em 20 frentes rastreáveis. Testes e jobs de CI não são
contados como agentes.

## Vinte frentes de revisão

| Frente | Decisão / evidência | Limite de validação |
|---|---|---|
| 01. Histórico e origem | 45 commits inventariados; 18 já presentes; 27 novos | Árvore final e ancestrais verificados na publicação do candidato |
| 02. Dependências nativas | Monero permanece no pin já adotado; BitBox usa novo pin e lockfile real | A biblioteca nova ainda exige compilação Windows/Linux |
| 03. Sincronização XMR | Preservados guards de sessão, resposta atrasada e confirmação nativa | 27 checks de estabilidade passaram; não é benchmark mainnet |
| 04. Persistência XMR | Mantidos serialização, await de gravação e backup posterior | Reabertura/senha incorreta/identidade continuam gates nativos do CI |
| 05. Perfil Linux | Teste C++ de exclusão entre processos, Unicode e symlinks passou | Não cobre todas as versões históricas de perfil |
| 06. Reconexão Electrum | Incorporados deadlines e gerações de conexão do upstream | Suites novas incluídas no CI; execução Flutter integral pendente |
| 07. Endereços BTC/LTC | Índice de derivação substitui contagem de registros | Testes de gap/descoberta/adress picker incluídos no CI |
| 08. Migração antiga | Arquivo da carteira prevalece sobre inferência pelo mnemonic; null não vira caminho vazio | Sem migração de carteiras reais do usuário |
| 09. Seeds BIP39 | 52 vetores de compatibilidade passaram com o código otimizado | Sem normalização Unicode nova; identidade antiga preservada nos vetores |
| 10. Inicialização EVM | Removido trabalho duplicado de tokens e save; init() já o executa | Ganho de tempo não medido |
| 11. Envio HTTP | IPv6 escolhido antes do POST; falha de resposta não causa replay | 10 checks locais de transporte passaram |
| 12. Transação EVM | Preservadas identidade da rede, contrato/decimais, ABI ERC20 e proteção de envio duplicado | Suites do fork continuam obrigatórias; sem pagamento real |
| 13. Backup | Zip Slip já era corrigido no fork; proteção preservada | Não equivale a auditoria completa de todos os formatos |
| 14. PIN e 2FA | 2FA não dispensável já presente; novos testes de PIN ilegível incluídos | Testes de interface/secure storage completos ainda dependem do CI |
| 15. Startup e banco | Leituras seguras paralelas, gravações em lote e menos consultas repetidas | Não alegado percentual de aceleração |
| 16. Interface | Modal de geração de transação, formatos locais e changelog PT-BR integrados | Revisão visual desktop completa pendente |
| 17. Hardware e moedas fora do perfil | APIs BitBox atualizadas; Zcash/NU7 ficam no código, mas não são habilitados no PC | Sem aparelho físico; não anunciar Zcash/Ledger como funcional neste perfil |
| 18. Pacote DEB | Mantida base Ubuntu 24.04, dependências e teste de instalação/remoção sem apagar perfil | Binário 6.5.3 depende do build; DEB não é para Arch/Fedora |
| 19. AppImage | Packager com ferramentas/hashes fixos, provenance e bibliotecas selecionadas | 10 testes de empacotamento e AppImage sintético passaram; não o binário final |
| 20. Portabilidade e liberação | Matriz Ubuntu 24.04/26.04, Fedora 44/45 e Arch com bases por digest | Gate configurado; não afirmar que passou sem o resultado do CI |

## Pontos críticos da integração

### IPv6 sem repetir transferência

O upstream tentava um POST em IPv6 e, capturando erro, podia executar outro POST
pelo caminho normal. Falha após o servidor receber uma operação não prova que
ela não ocorreu. O fork também já possuía timeout e fechamento de cliente que
não podiam ser perdidos na mesclagem.

A preferência passou a ocorrer na conexão TCP/TLS, antes do envio HTTP. Mantidos
timeout, fechamento do cliente, proxy explícito e roteamento Tor. Os testes usam
servidores loopback e verificam falha após recebimento, timeout, cancelamento de
DNS e ausência de replay. HTTPS usa o hostname original e rejeita certificados
não confiáveis e nomes divergentes. Não foi ativado bypass TLS por padrão.

Dois problemas intermediários foram reproduzidos e corrigidos antes da validação:
lookup genérico omitindo IPv6 no ambiente e necessidade de a connectionFactory
customizada entregar SecureSocket para HTTPS. O resultado final é o registrado
em CAKE_PC_V653_LOCAL_TESTS.json, não o dos rascunhos.

### Seeds: compatibilidade antes de velocidade

A nova função de derivação foi executada com 52 vetores fixos do upstream que
representam o comportamento da biblioteca usada anteriormente. Eles incluem
NFC/NFD, idiomas distintos, passphrases Unicode, espaços e caracteres especiais.
Não foi feita normalização adicional: alterar bytes de entrada pode gerar outra
carteira. Os vetores verificam compatibilidade; não demonstram aceleração medida.

### Reconexão e endereços

Os reparos Electrum eliminam conexões antigas interferindo na nova sessão,
reestabelecem inscrições após trocar nó, limitam handshakes e cancelam retries
de carteiras fechadas. Os testes de reconexão e descoberta foram acrescentados
aos comandos efetivamente chamados no CI do fork, não apenas copiados para o
repositório.

As correções de migração priorizam o tipo gravado no arquivo e preservam null
para caminho de derivação ausente. Isso evita interpretar caminho vazio como
chave mestre. Endereços novos/troco usam índices reais, prevenindo buracos
causados pela contagem conjunta de registros de derivações diferentes.

### O que não é novo e não deve ser perdido

O fork já continha: proteção Zip Slip; 2FA obrigatório não dispensável;
fechamento Monero aguardado; checagens adicionais de RBF; retirada de chainId do
QR de swap; e outras correções do início do intervalo. Também preserva suas
proteções adicionais de chainId, contrato/decimais ERC20, payload ABI e
serialização de disco. Integrar upstream não autoriza remover esses guards.

### Limitações que permanecem

O fallback visual de saldo zero ao falhar a primeira consulta de um novo token
EVM não prova saldo real zero. Conexão RPC, histórico indexado e descoberta de
tokens são capacidades distintas; ausência de chave de provedor não equivale a
histórico completo. Não foram realizados pagamentos mainnet, restaurações de
carteiras financiadas nem testes físicos de hardware wallet.

O código Zcash Ledger/NU7 e melhorias iOS/macOS fazem parte da release upstream,
mas não são suporte ativo no perfil PC. Tampouco foi empacotado um binário Tor.

## Empacotamento e plataformas

DEB: Ubuntu x86-64, baseline 24.04, glibc >= 2.39. AppImage: mesmos requisitos
fundamentais, com bibliotecas ABI específicas incluídas e seus copyrights e
hashes registrados. GTK3, Secret Service e drivers gráficos permanecem no host.
Não são empacotadas glibc ou libstdc++ antigas que poderiam quebrar Mesa moderno.

As imagens de teste foram resolvidas no registry e fixadas por digest. A matriz
inclui Ubuntu 24.04/26.04, Fedora 44/45 e Arch snapshot 20261101. Arch rolling
exige revalidação com o tempo. Ubuntu 22.04, musl/Alpine e ARM não são suportados
por esses binários. Não usar conversão de DEB para instalar em Fedora/Arch.

O teste entre distribuições roda sem rede, sem privilégios e sem montar carteiras
reais. Verifica hashes, dependências ELF, Secret Service real com canário
aleatório, janela X11 visível e exclusão de segunda instância. A extração do
AppImage evita conceder /dev/fuse ao container; não valida montagem FUSE em
máquina real. Wayland/GPU/desktop físico continuam testes separados.

A publicação da release depende de Windows, Linux, XMR nativo e de toda a matriz
AppImage. O manifesto passa a exigir cinco arquivos: Windows EXE/ZIP, Linux
DEB/TAR.GZ/AppImage. Falta de um artefato ou um gate impede publicação.

## Testes já executados neste trabalho

- 10 checks de transporte em Dart 3.13.7: aprovados, loopback apenas.
- 27 checks existentes de estabilidade/concorrência/sincronização: aprovados.
- 52 vetores de compatibilidade da derivação BIP39: aprovados, dependência fixada.
- 10 testes unitários de empacotamento: aprovados, arquivos sintéticos.
- Suite C++ nativa de bloqueio/exclusão de perfil: compilada e aprovada.
- Ferramentas AppImage fixadas por SHA-256: empacotaram e executaram aplicação
  sintética com extract-and-run. Isso não é teste da carteira final.
- Lockfile BitBox: fonte e revisão resolvidas verificadas.

O ambiente local foi uma VM Ubuntu 26.10 x86-64. Não confundir esses checks com
compilação Flutter completa, verificação de instaladores 6.5.3 ou matriz de
runtimes. Os resultados completos do CI são a condição para liberar binários.

## Inventário integral dos 45 commits

“Já presente” significa ancestral do fork antes deste trabalho. “Integrado no
candidato” não significa automaticamente testado em todas as plataformas.

| Commit | Situação na integração | Melhoria / alcance |
|---|---|---|
| `e0d2ba25` | Já presente | Protege a extração de backup contra caminhos que escapem do destino (Zip Slip). |
| `160d710a` | Já presente | Atualiza traduções alemãs. |
| `d4739e47` | Já presente | Atualiza traduções. |
| `c579e50e` | Já presente | Mostra erro mais claro para QR de carteira sem backend disponível. |
| `75fa8961` | Já presente | Inclui BTCMap na lista de aplicativos; não altera o processamento de pagamentos. |
| `5aec35b4` | Já presente | Impede dispensar a etapa de 2FA necessária para acessar a carteira. |
| `970e47a5` | Já presente | Ajusta o script de geração de modelos. |
| `aaaea05e` | Já presente | Melhora o seletor de carteiras e seus casos de interface. |
| `75eee6ba` | Já presente | Renomeia a opção Cash App Pay no provedor MoonPay. |
| `2caafc67` | Já presente | Ajustes diversos de interface/modelos; ver lista completa de arquivos no inventário JSON. |
| `49b48988` | Já presente | Adiciona workflow de testes unitários upstream; não substitui os gates desktop do fork. |
| `03f27548` | Já presente | Converte corretamente a lista JSON de solana_signAllTransactions. |
| `ec6fd6a8` | Já presente | Restaura a assinatura de LNURL.getPayRequestAmount e corrige compilação. |
| `1772b762` | Já presente | Remove chainId EVM do QR ao interpretar endereço de recebimento de swap. |
| `0fe6dde2` | Já presente | Verifica se a transação retornada para RBF corresponde à original. |
| `98fa3e44` | Já presente | Adiciona Arbitrum à integração MoonPay; depende do provedor externo. |
| `f1c558cf` | Já presente | Trata compartilhamentos simultâneos no iOS; fora dos binários PC. |
| `162a688d` | Já presente | Aguarda fechamento nativo Monero antes de apagar arquivos em fluxo de remoção. |
| `9488b544` | Integrado no candidato | Expande CI/build de iOS; preservado como histórico, não é suporte PC. |
| `e2c55515` | Integrado no candidato | Acelera derivação BIP39/abertura, preservando os resultados históricos da derivação. |
| `de159ddb` | Integrado no candidato | Adiciona Zcash a Ledger; o backend Zcash continua desabilitado no perfil PC. |
| `4688efd4` | Integrado no candidato | Corrige reconexão Electrum, deadlines TLS/SOCKS, sockets atrasados, ressubscrição e timers após fechar. |
| `53784d2f` | Integrado no candidato | Usa índices de derivação reais em novos endereços/troco/descoberta, não quantidade de linhas. |
| `ca930515` | Integrado no candidato | Preserva derivação registrada no arquivo e caminho ausente como null em migrações antigas. |
| `2527ac60` | Integrado no candidato | Remove repetição de cadastro de tokens/salvamento depois de init() EVM. |
| `0568f492` | Integrado no candidato | Agrupa gravações de endereços no banco em lote. |
| `5e996113` | Integrado no candidato | Carrega metadados das carteiras uma vez ao validar diretórios na inicialização. |
| `cf7d8088` | Integrado no candidato | Retira espera de preferências não críticas ao alternar carteira; não retira espera de gravação Monero. |
| `72498e87` | Integrado no candidato | Evita inicializar endereços Zcash duas vezes; backend fora do perfil PC. |
| `02252601` | Integrado no candidato | Evita abortar cadastro de token EVM em falha de consulta; fallback visual zero não comprova saldo real. |
| `19457943` | Integrado no candidato | Prefere IPv6 nos provedores MoonPay/Onramper. Adaptado no fork para não reenviar POST após falha. |
| `ec61b405` | Integrado no candidato | Acrescenta testes de PIN ilegível/IPv6, ajustes de autenticação e configuração Apple. |
| `3984c3a7` | Integrado no candidato | Lê configurações do armazenamento seguro em paralelo na inicialização. |
| `389134e4` | Integrado no candidato | Executa a espera de fallback de ações rápidas junto com o trabalho de startup. |
| `89f5de4b` | Integrado no candidato | Fortalece conversões/tipos nulos em múltiplas moedas; testes de execução continuam necessários. |
| `bedf18df` | Integrado no candidato | Atualiza metadados de versão. |
| `99bba541` | Integrado no candidato | Reutiliza o novo derivador em seeds HD Nano e adiciona comparação com nanoutil. |
| `ac1b649d` | Integrado no candidato | Adiciona horário às entradas lightning.log. |
| `772c8b00` | Integrado no candidato | Atualiza endpoint onion de preços com balanceamento; não empacota Tor no PC. |
| `7f7fc4a2` | Integrado no candidato | Atualiza APIs e biblioteca BitBox, pareamento e integração hardware. Sem validação física neste trabalho. |
| `71e84526` | Integrado no candidato | Prepara Zcash para NU7; não habilita Zcash no perfil PC. |
| `b469f58d` | Integrado no candidato | Adiciona tipografia IBM Plex Sans para preços de gráficos. |
| `0333c845` | Integrado no candidato | Aplica separador de milhar conforme localidade aos preços dos gráficos. |
| `f75a175b` | Integrado no candidato | Mostra geração de transação em modal completo; proteção de broadcast continua necessária. |
| `d803aecf` | Integrado no candidato | Marca a release upstream 6.5.3. |
