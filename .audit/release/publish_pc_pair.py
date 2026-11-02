#!/usr/bin/env python3
"""Assemble immutable, already-tested platform artifacts; never relabel builds."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile

REPO = 'vitorhubdev/cake_wallet_win'
UPSTREAM = '4f792ca4a9981961bdc368ad34ba4c8d40c928b1'
WINDOWS = '4adc55187f55a4c4d0a31b4e38056c2bee760264'
LINUX = '1022d5751ca5813fbf6c8643ac775d789faf24d0'
TAG = 'pc-v6.5.2-desktop.1'
SOURCE = Path(os.environ['PC_SOURCE_DIR'])
DIST = Path('dist').resolve()
EXPECTED = {
    'CakeWalletPC-Windows-x64-6.5.2-1003-Setup.exe': '6437e7ec6b52367139e3aac2f2ddfa3a59e9d4bd3773109ff66a22aec31db874',
    'CakeWalletPC-Windows-x64-6.5.2-1003.zip': '0775efb51e6ef1a319d5ffdc97d4d83fa9fc83223e97d35aaa1bbb6db7863f9d',
    'CakeWalletPC-Linux-x64-6.5.2-1005.deb': 'e20e384d841d91d1b9bead62266b35024426ac218d563697f5ee4dda744162a2',
    'CakeWalletPC-Linux-x64-6.5.2-1005.tar.gz': 'e28fae88272ec8c18bb83d3ad970284d50dbdda0ed3caa9477678e337408784a',
}
PLATFORMS = [
    dict(platform='Windows', build=1003, source=WINDOWS, run=41352979560, job=124987233780,
         artifact=13105126369, name='pc-Windows-distribution',
         digest='daa049d9c59d7d7621cba9c13a8b16145842a0179af0d470c796510525e7f84a',
         gates=['Deterministic concurrency and synchronization regressions',
                'Native Windows profile exclusion and Unicode path regression',
                'Generate Windows application and run EVM/XMR regressions',
                'Compile Windows release and package all native runtimes',
                'Verify real Windows DLLs, offline XMR storage and visible process',
                'Verify real Windows onboarding and secure storage',
                'Package Windows portable ZIP and installer']),
    dict(platform='Linux', build=1005, source=LINUX, run=41372228272, job=125045157058,
         artifact=13109779692, name='pc-Linux-distribution',
         digest='18cff59882dfb2e18892140be55ed1fa4aafc914d6487982f6511e8a9e9e9472',
         gates=['Deterministic concurrency and synchronization regressions',
                'Native Linux profile exclusion and symlink protection',
                'Generate Linux application and run EVM/XMR regressions',
                'Verify Linux runtime and pinned native ABI before compilation',
                'Compile Linux release and package all native runtimes',
                'Verify real Linux offline XMR creation, identity and concurrent storage',
                'Verify real Linux onboarding and isolated Secret Service',
                'Package and verify Linux portable bundle and DEB installation']),
]


def command(args, **kwargs):
    return subprocess.run(args, check=True, timeout=180, **kwargs)


def api(path):
    return json.loads(command(['gh', 'api', f'repos/{REPO}/{path}'], capture_output=True, text=True).stdout)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    return command(['git', '-C', str(SOURCE), *args], capture_output=True, text=True).stdout


def verify_source_delta():
    for source in (WINDOWS, LINUX):
        git('merge-base', '--is-ancestor', UPSTREAM, source)
    git('merge-base', '--is-ancestor', WINDOWS, LINUX)
    expected = {
        '.github/workflows/pc-linux-abi-regression.yml', '.github/workflows/pc-release.yml',
        'cw_monero/lib/monero_wallet.dart', 'cw_monero/lib/monero_wallet_service.dart',
        'lib/core/wallet_loading_service.dart', 'docs/builds/CAKE_WALLET_PC.md',
        'scripts/pc/build_linux.sh', 'scripts/pc/package_linux.py',
        'scripts/pc/verify_linux_runtime.py', 'test/core/windows_wallet_loading_test.dart',
    }
    changed = set(git('diff', '--name-only', WINDOWS, LINUX).splitlines())
    if changed != expected:
        raise ValueError('Unexpected source differences; do not reuse the Windows build')
    rules = {
        'cw_monero/lib/monero_wallet.dart': [
            ('if (!Platform.isWindows) {', 'if (!(Platform.isWindows || Platform.isLinux)) {'),
            ('Do not discard a Windows cache, TX keys or Polyseed', 'Do not discard a desktop cache, TX keys or Polyseed')],
        'cw_monero/lib/monero_wallet_service.dart': [
            ('if (Platform.isWindows) rethrow;', 'if (Platform.isWindows || Platform.isLinux) rethrow;')],
        'lib/core/wallet_loading_service.dart': [
            ('if (Platform.isWindows && type == WalletType.monero) rethrow;',
             'if ((Platform.isWindows || Platform.isLinux) && type == WalletType.monero) rethrow;'),
            ('Windows XMR open failures', 'Desktop XMR open failures')],
    }
    for path, replacements in rules.items():
        previous = git('show', WINDOWS + ':' + path)
        for before, after in replacements:
            if previous.count(before) != 1:
                raise ValueError('Source guard differs from reviewed change')
            previous = previous.replace(before, after)
        if previous != git('show', LINUX + ':' + path):
            raise ValueError('An application change goes beyond the reviewed Linux-only guards')
    return sorted(changed)


def verify_platform(platform):
    run = api(f"actions/runs/{platform['run']}")
    if (run['head_sha'] != platform['source'] or run['event'] != 'push'
            or run['head_repository']['full_name'] != REPO or run['head_branch'] != 'main'):
        raise ValueError('Unexpected source-run provenance')
    job = api(f"actions/jobs/{platform['job']}")
    if (job['run_id'] != platform['run'] or job['head_sha'] != platform['source']
            or job['status'] != 'completed' or job['conclusion'] != 'success'):
        raise ValueError('Selected platform did not complete successfully')
    steps = job['steps']
    if any(step['conclusion'] in ('failure', 'cancelled', 'timed_out') for step in steps):
        raise ValueError('Selected platform contains a failed step')
    for name in platform['gates']:
        matches = [step for step in steps if step['name'] == name]
        if len(matches) != 1 or matches[0]['conclusion'] != 'success':
            raise ValueError('A required platform gate was not executed successfully: ' + name)
    artifact = api(f"actions/artifacts/{platform['artifact']}")
    if (artifact['expired'] or artifact['name'] != platform['name']
            or artifact['workflow_run']['id'] != platform['run']
            or artifact['workflow_run']['head_sha'] != platform['source']
            or artifact['digest'] != 'sha256:' + platform['digest']):
        raise ValueError('Artifact provenance or digest mismatch')
    archive = DIST.parent / (platform['platform'] + '-verified-artifact.zip')
    with archive.open('wb') as target:
        command(['gh', 'api', '--allow-escape-sequences',
                 f"repos/{REPO}/actions/artifacts/{platform['artifact']}/zip"], stdout=target)
    if sha(archive) != platform['digest']:
        raise ValueError('Downloaded artifact bytes do not match the verified artifact')
    names = {name for name in EXPECTED if '-' + platform['platform'] + '-' in name}
    with zipfile.ZipFile(archive) as zipped:
        for name in names:
            if zipped.namelist().count(name) != 1:
                raise ValueError('Missing or duplicated installer asset')
            with zipped.open(name) as source, (DIST / name).open('wb') as target:
                shutil.copyfileobj(source, target)
            if sha(DIST / name) != EXPECTED[name]:
                raise ValueError('Installer checksum mismatch')
    if platform['platform'] == 'Windows':
        with zipfile.ZipFile(DIST / 'CakeWalletPC-Windows-x64-6.5.2-1003.zip') as package:
            info = json.loads(package.read('build-info.json'))
            dependencies = json.loads(package.read('dependency-manifest.json'))
            for name in ['CakeWallet.exe', 'flutter_windows.dll', 'libmonero_wallet2_api_c.dll', 'data/icudtl.dat']:
                if package.getinfo(name).file_size <= 0:
                    raise ValueError('Incomplete Windows application bundle')
    else:
        with tarfile.open(DIST / 'CakeWalletPC-Linux-x64-6.5.2-1005.tar.gz') as package:
            prefix = 'CakeWalletPC-Linux-x64-6.5.2-1005/'
            info = json.load(package.extractfile(prefix + 'build-info.json'))
            dependencies = json.load(package.extractfile(prefix + 'dependency-manifest.json'))
            for name in ['cake_wallet_pc', 'cake-wallet-pc', 'lib/libmonero_wallet2_api_c.so', 'data/icudtl.dat']:
                if not package.getmember(prefix + name).isfile():
                    raise ValueError('Incomplete Linux application bundle')
        control = command(['dpkg-deb', '--field', str(DIST / 'CakeWalletPC-Linux-x64-6.5.2-1005.deb')], capture_output=True, text=True).stdout
        for requirement in ['Version: 6.5.2-1005', 'Architecture: amd64', 'libc6 (>= 2.39)', 'libgtk-3-0t64', 'libssl3t64']:
            if requirement not in control:
                raise ValueError('Incorrect Linux installer compatibility metadata')
    if (info['commit'] != platform['source'] or info['version'] != '6.5.2+' + str(platform['build'])
            or info['upstreamVersion'] != '6.5.2' or info['upstreamCommit'] != UPSTREAM):
        raise ValueError('Binary source identity does not match the passing platform run')
    if dependencies['monero_c']['commit'] != '33671871de3d51696b66ffb3bd94f744e26974f6':
        raise ValueError('Unexpected native Monero revision')
    return dict(platform=platform['platform'], build=platform['build'], source=platform['source'],
                sourceUrl=f"https://github.com/{REPO}/tree/{platform['source']}",
                run=platform['run'], job=platform['job'], artifact=platform['artifact'],
                workflowConclusion=run['conclusion'], platformConclusion=job['conclusion'],
                passingRequiredSteps=platform['gates'], buildInfo=info,
                assets={name: EXPECTED[name] for name in sorted(names)})


def main():
    DIST.mkdir(exist_ok=False)
    changed = verify_source_delta()
    platforms = [verify_platform(platform) for platform in PLATFORMS]
    manifest = {
        'product': 'Cake Wallet PC', 'upstreamVersion': '6.5.2', 'upstreamCommit': UPSTREAM,
        'releaseTag': TAG, 'sourceArchiveTagTarget': LINUX,
        'platformsUseDifferentBuildNumbers': True, 'artifactsRebuiltOrRelabeled': False,
        'platforms': platforms, 'reviewedSourceDelta': changed,
        'reuseReason': 'Windows 1003 passed all Windows gates. The additional application edits in Linux 1005 only extend existing Windows guards to Linux; their exact forms are checked. Linux 1005 also corrects the Linux runtime and packaging. No failed Linux artifact from the earlier run is distributed.',
        'limitations': ['Community prerelease; unsigned Windows installer',
                        'Linux requires Ubuntu 24.04-compatible x86-64 desktop runtime',
                        'No claim of all bugs removed or mainnet payment/hardware-wallet certification',
                        'No measured blockchain synchronization speedup',
                        'Commercial provider keys are not included'],
    }
    (DIST / 'SOURCE-MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (DIST / 'SHA256SUMS.txt').write_text(''.join(f'{sha(path)}  {path.name}\n' for path in sorted(DIST.iterdir())), encoding='ascii')
    notes = '''# Cake Wallet PC 6.5.2 — Windows + Linux

Versão comunitária, não oficial da Cake Labs, publicada como pré-lançamento.

## Downloads

- **Windows x64:** `CakeWalletPC-Windows-x64-6.5.2-1003-Setup.exe`; ZIP portátil completo também disponível.
- **Linux x86-64:** `CakeWalletPC-Linux-x64-6.5.2-1005.deb`; arquivo portátil `.tar.gz` também disponível.
- `SHA256SUMS.txt` verifica a integridade; `SOURCE-MANIFEST.json` identifica fontes, builds, execuções e testes de cada plataforma.

**Os números de build são diferentes e foram preservados, sem reempacotar ou renomear binários.** Windows 1003 foi aprovado integralmente no CI; Linux 1005 acrescenta a correção de compatibilidade do Linux e estende ao Linux as proteções de XMR já existentes no Windows. O publicador verifica os testes aprovados de cada plataforma, os hashes dos artefatos, os metadados internos e as mudanças exatas entre os commits. Não distribui o pacote Linux que falhou na execução anterior. Uma nova compilação Windows 1005 pode ainda estar em andamento; ela não é apresentada como concluída nesta release.

## Integração e correções

Ambas as fontes contêm o upstream `v6.5.2` (`4f792ca4a9981961bdc368ad34ba4c8d40c928b1`), confirmado por ancestralidade. Foram preservadas as atualizações upstream e as correções locais, sem aplicar commits duplicados.

- **XMR:** gravações aguardadas e serializadas antes do backup; proteção contra resultados tardios e consultas sobrepostas; checkpoints limitados; conclusão da sincronização exige zero blocos restantes e confirmação nativa. Erros comuns não provocam remoção automática do cache, extração de seed ou abertura de outra carteira.
- **Ethereum/EVM:** hash dos bytes realmente assinados; uma transmissão por objeto pendente, sem repetição automática após sucesso; proteção contra troca de rede durante assinatura ou respostas atrasadas; validação de `eth_chainId`; histórico isolado por rede; tokens identificados por contrato/rede/decimais; múltiplos destinatários não suportados são recusados; memos nativos em UTF-8 e preservação do calldata ERC20.
- **Desktop:** nome Cake Wallet PC, navegação desktop, painel de conexão sem exibir credenciais RPC, bloqueio de segunda instância no mesmo perfil. A identidade de instalação/armazenamento Windows anterior foi preservada.
- **Linux:** build e bibliotecas agora usam Ubuntu 24.04; validação antecipada de ABI, dependências e carregamento real; dependências DEB corrigidas, incluindo pacotes t64. Perfil e chaveiro próprios, sem alterar os dados da carteira oficial.

## Testes executados

Windows: regressões EVM/XMR, carregamento de DLLs, abertura da janela, carteira XMR testnet descartável com gravação/reabertura e rejeição de senha incorreta, armazenamento concorrente, onboarding/chaveiro reais, instalação, atualização sobre o build 12 e desinstalação.

Linux: regressões EVM/XMR, compatibilidade ELF/ABI, carteira XMR testnet descartável e armazenamento concorrente, onboarding com Secret Service real, bloqueio de perfil, geração/instalação/abertura/remoção do DEB e pacote portátil.

As verificações usam carteiras descartáveis e sem fundos. Não certificam pagamentos mainnet, todos os dispositivos físicos, integrações comerciais ou ausência de todos os defeitos. Não foi removida validação de blocos nem elevada a altura de recuperação para alegar aceleração.

## Instalação e limites

Linux: Ubuntu 24.04 ou derivada com o mesmo runtime, x86-64, glibc >= 2.39 e libstdc++ >= 13.2, GTK3 e Secret Service. Instale com `sudo apt install ./CakeWalletPC-Linux-x64-6.5.2-1005.deb`. O `.tar.gz` exige as mesmas bibliotecas; extraia e execute `./cake-wallet-pc`. Ubuntu 22.04, ARM, musl e 32 bits não são suportados por estes binários. Flatpak não é necessário para estes pacotes e não foi qualificado nesta release.

Windows: instalador sem assinatura comercial. O nome visível mudou, mas o diretório `CakeWalletWindows` e a identidade de credenciais foram mantidos. Pastas com acentos dependem de um alias NTFS 8.3 disponível; nomes de arquivo de carteira não ASCII são recusados quando não podem ser abertos com segurança. Não renomeie manualmente a pasta de dados.

Chaves comerciais Cake/Etherscan não estão incluídas; consulta RPC e descoberta/histórico por indexadores são capacidades distintas. Wownero, Zcash, Zano, Decred e Tor empacotado não integram este perfil. Faça backup e valide uma carteira vazia antes de usar fundos. Não transplante diretórios cifrados de outra distribuição.

## Fontes e evidências

- Windows 1003: https://github.com/vitorhubdev/cake_wallet_win/tree/4adc55187f55a4c4d0a31b4e38056c2bee760264
- CI Windows aprovado: https://github.com/vitorhubdev/cake_wallet_win/actions/runs/41352979560/job/124987233780
- Linux 1005: https://github.com/vitorhubdev/cake_wallet_win/tree/1022d5751ca5813fbf6c8643ac775d789faf24d0
- CI Linux aprovado: https://github.com/vitorhubdev/cake_wallet_win/actions/runs/41372228272/job/125045157058

O arquivo de fontes automático da tag corresponde ao commit Linux; a fonte exata do Windows está vinculada acima e no manifesto. Checksums verificam integridade, não substituem assinatura de autenticidade.
'''
    Path('release-notes.md').write_text(notes)
    existing = subprocess.run(['gh', 'release', 'view', TAG, '--repo', REPO, '--json', 'isDraft,tagName'], capture_output=True, text=True, timeout=30)
    if existing.returncode == 0:
        raise RuntimeError('Release tag already exists; refusing to replace any published artifact')
    command(['gh', 'release', 'create', TAG, '--repo', REPO, '--target', LINUX,
             '--draft', '--prerelease', '--title', 'Cake Wallet PC 6.5.2 — Windows + Linux',
             '--notes-file', 'release-notes.md'])
    command(['gh', 'release', 'upload', TAG, '--repo', REPO, *map(str, sorted(DIST.iterdir()))])
    release = api('releases/tags/' + TAG)
    assets = {asset['name']: asset for asset in release['assets']}
    if set(assets) != {path.name for path in DIST.iterdir()}:
        raise ValueError('The draft release does not contain the exact validated asset set')
    for path in DIST.iterdir():
        item = assets[path.name]
        if item['state'] != 'uploaded' or item['size'] != path.stat().st_size or item['digest'] != 'sha256:' + sha(path):
            raise ValueError('Uploaded release asset failed its final digest check')
    command(['gh', 'release', 'edit', TAG, '--repo', REPO, '--draft=false'])
    release = api('releases/tags/' + TAG)
    if release['draft'] or not release['published_at']:
        raise ValueError('Release is not publicly published')
    print(release['html_url'])
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write('Published verified Windows 1003 + Linux 1005: ' + release['html_url'] + '\n')


if __name__ == '__main__':
    main()
