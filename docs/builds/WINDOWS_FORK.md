# Cake Wallet para Windows x64 — fork comunitário

Este build é mantido em `vitorhubdev/cake_wallet_win`. É uma distribuição
comunitária, independente dos lançamentos oficiais da Cake Labs. O CI utiliza
Windows Server 2022, Visual Studio 2022, Flutter 3.41.9 e as dependências fixadas
pelo projeto original.

## Baixar e executar

Abra [Releases](https://github.com/vitorhubdev/cake_wallet_win/releases) e baixe o
ZIP da versão Windows desejada. A publicação acontece somente quando todos os
checks obrigatórios do workflow passam.

1. Extraia **todo** o ZIP em uma pasta na qual você tenha permissão de escrita.
2. Mantenha as DLLs e a pasta `data` junto de `CakeWallet.exe`.
3. Execute `CakeWallet.exe`. Não copie apenas o executável para outra pasta.

O pacote é destinado a Windows 10/11 de 64 bits, em processadores Intel/AMD.
Não é um build ARM64 e não possui assinatura digital da Cake Labs. Os arquivos
`SHA256SUMS.txt`, `build-info.json`, `build-pubspec.lock` e
`dependency-manifest.json` identificam o pacote e seus insumos.

Para conferir o ZIP no PowerShell:

```powershell
Get-FileHash .\CakeWallet-Windows-x64-6.5.0-N.zip -Algorithm SHA256
```

Substitua `N` pelo número do build e compare o resultado com `SHA256SUMS.txt`.
Os artefatos também ficam em **Actions → Windows x64 → execução aprovada →
Artifacts → CakeWallet-Windows-x64**. Nesse caso, extraia o arquivo de artefatos
e depois o ZIP portátil que ele contém.

## Experiência Windows com foco em Monero

O painel do XMR mantém o estado de conexão, o progresso real da sincronização
e o hostname/porta do nó visíveis. **Gerenciar nós** abre a tela existente para
escolher outro servidor ou configurar o seu. Credenciais do nó não são mostradas
no endereço do painel. A troca automática experimental continua desativada.

Janelas largas usam navegação lateral com rótulos e conteúdo centralizado;
janelas pequenas mantêm a navegação compacta. As seções do painel Windows são
criadas na primeira visita e preservam seu estado depois disso. A tela inicial
é estática, com textos em português e acesso por teclado aos controles.

As correções de reconexão evitam listeners duplicados, verificações concorrentes
e resultados tardios aplicados à carteira ou ao nó que já foram trocados. As
sondagens HTTP diretas do Monero têm um orçamento de dez segundos e fecham o
cliente ao concluir ou expirar, inclusive na autenticação digest. Isso não mede
nem promete redução do tempo de varredura da blockchain: a sincronização depende
do nó, da rede, do computador e da altura de restauração escolhida.

## Compilar pelo GitHub Actions

Envie alterações de código para `dev` ou `windows-ci`, ou use **Windows x64 →
Run workflow**. Não são necessários os secrets comerciais nem os servidores
privados da Cake Labs.

O job Linux compila a biblioteca MWEB para Windows. O job Windows prepara as
dependências, gera o código, executa testes, compila o app e reúne as bibliotecas
necessárias. Os downloads nativos pré-compilados têm SHA-256 fixado e verificado.

Antes de publicar, o workflow exige:

- Testes nativos de geração de endereços e liberação de memória do MWEB.
- Testes de estabilidade das constantes de compatibilidade entre builds.
- Regressões de reconexão, descarte de listeners e resultados antigos, além de
  sondagens Monero e autenticação digest contra sockets locais sem nós externos.
- Carregamento das DLLs e abertura do executável de release.
- Criação, gravação, fechamento e reabertura de uma carteira Monero **testnet**
  descartável, sem daemon, conexão de rede ou fundos; também rejeita senha errada.
- Abertura da tela inicial real, sem tela de erro, e verificação da pasta de
  dados, do banco e dos metadados de versão.

Os logs e as imagens de diagnóstico ficam em artefatos separados. Esses checks
não comprovam sincronização em mainnet, recuperação de todas as moedas, envio de
fundos, hardware wallets ou funcionamento de serviços comerciais.

## Moedas e integrações

A configuração segue o perfil Windows do projeto original: Monero,
Bitcoin/Litecoin, redes EVM, Nano, Bitcoin Cash, Solana, Tron e Dogecoin.
Zcash, Zano e Decred não são habilitados nesse perfil. A biblioteca MWEB é
compilada e incluída, mas isso não equivale a validar todos os fluxos Litecoin
na interface do Windows.

Este fork não contém chaves de produção pertencentes à Cake Labs. Integrações
que exigem essas credenciais — como determinados provedores de troca,
compra/venda, cotações, WalletConnect e Lightning — podem ficar indisponíveis.
O pacote Torch fixado pelo projeto não fornece uma biblioteca Tor para Windows.
A implementação Windows de BitBox está incompleta e a interface upstream já a
marca como indisponível. Não presuma que todos os recursos das versões móveis
estão presentes aqui.

## Dados, atualizações e compatibilidade

A pasta nativa deste fork é `%APPDATA%\vitorhubdev\Cake Wallet Windows`.
O prefixo das credenciais legadas também é exclusivo do fork. Mantenha esses
identificadores estáveis para que futuras versões encontrem os mesmos dados,
sem misturar informações de outras variantes do Cake Wallet.

`tool/configure_windows_secrets.dart` define constantes públicas e estáveis de
compatibilidade deste fork. Elas fazem parte do binário; não são seeds de
carteiras nem credenciais de API. **Não as regenere a cada build:** alterá-las
pode impedir a leitura de PINs, senhas cifradas, backups e grupos já existentes.
O armazenamento seguro Windows original, com DPAPI, permanece habilitado.

Não há promessa de compatibilidade de pastas ou backups cifrados com builds
que utilizam outras constantes, inclusive binários oficiais da Cake.
Guarde a frase de recuperação com segurança antes de migrar entre variantes.
Antes de utilizar fundos, valide criação, fechamento/reabertura e recuperação
com uma carteira nova e vazia no seu próprio computador.

## Compilar localmente

Use as mesmas versões fixadas, PowerShell 7, Python 3.11+, Rust, LLVM, NuGet e
Visual Studio com a carga **Desenvolvimento para desktop com C++**.
Prepare o artefato nativo com `scripts/windows/build_mweb.sh` em Linux/WSL e
coloque o resultado em `build/windows-native/` no Windows. Então execute:

```powershell
./scripts/windows/build.ps1 -Version 6.5.0 -BuildNumber 1
```

O parâmetro `-Stage` permite executar separadamente `Configure`, `Generate` e
`Build`; por padrão, o script executa todas as etapas. O antigo `cakewallet.bat`
foi substituído por esse fluxo PowerShell.

Use um runner Windows descartável do GitHub para `smoke_test.ps1`. O script
recusa o teste de abertura em um perfil pessoal. Nunca forneça seeds reais ao CI.
