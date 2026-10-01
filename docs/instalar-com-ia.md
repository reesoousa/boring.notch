# Instalar o boringCode — guia para agentes de IA

> Este guia é para um agente de IA (Claude Code, Codex, Cursor…) instalar o boringCode no Mac da pessoa
> que pediu. Pessoas também podem seguir: é só rodar o comando do passo 2.

O boringCode é um app de barra de menus para macOS que transforma o notch num painel (música, calendário,
shelf, agentes de IA, encaixe de janelas). **Não precisa compilar nem clonar o repositório**: a instalação
baixa o DMG assinado da Release mais recente do GitHub.

## 1. Conferir o Mac

```bash
sw_vers -productVersion   # precisa ser 14 ou maior
```

Se for menor que 14, pare e explique que o boringCode precisa do macOS 14 (Sonoma) ou mais novo. Funciona em
Apple Silicon e Intel.

## 2. Instalar

```bash
curl -fsSL https://raw.githubusercontent.com/reesoousa/boringCode/HEAD/scripts/install.sh | bash
```

O script ([`scripts/install.sh`](../scripts/install.sh)):

- usa só ferramentas do macOS e não pede nada interativo;
- baixa o DMG da Release mais recente e confere o SHA-256 publicado pelo GitHub;
- confere a assinatura do app;
- instala em `/Applications`, ou em `~/Applications` se não tiver permissão para escrever lá;
- abre o app.

Se o boringCode já estiver instalado, o script atualiza a cópia que já existe.

- Precisa de internet (`api.github.com`, `github.com`, `objects.githubusercontent.com`). Se o seu ambiente
  roda comandos em sandbox, peça permissão para rodar este comando com rede e acesso a `/Applications`.
- **Não use `sudo`.** Se faltar permissão, o script cai sozinho para `~/Applications`.
- Opções (via `bash -s --`):
  - `--no-open`: só instala;
  - `--version 0.5.0`: instala uma versão específica;
  - `--uninstall`: desinstala.
- Se o script terminar com `✗`, mostre a mensagem para a pessoa. Ele não instala nada pela metade.

## 3. Conferir

```bash
defaults read /Applications/boringCode.app/Contents/Info CFBundleShortVersionString  # ou ~/Applications/…
pgrep -x boringCode && echo "rodando"
```

## 4. Explicar para a pessoa o que vem agora

Diga, com as suas palavras, mais ou menos isto:

1. Na primeira abertura aparecem as **boas-vindas**. Uma tela por recurso pergunta se você quer usar e, no
   "sim", o macOS pede a permissão daquele recurso:
   - **Agentes de IA** (Claude Code e Codex no notch): sem permissão do sistema. O app adiciona um hook nos
     ajustes do Claude Code e do Codex.
   - **Janelas e controles** (encaixar janelas arrastando até o notch, notificações, volume e brilho): pede
     **Acessibilidade**, que no macOS 27 se chama "Controle do Dispositivo e Acesso a Dados". A pessoa liga a
     chave do boringCode nos Ajustes do Sistema e volta. A tela segue sozinha.
   - **LocalSend** (trocar arquivos com o celular): pede Rede Local e a pasta Downloads.
   - **Espelho** (câmera), **calendário e lembretes**, **visualizador de áudio**.
2. "Agora não" deixa o recurso desligado; dá para mudar tudo depois em **Ajustes** (ícone do boringCode na
   barra de menus).
3. **Sessões novas** do Claude Code e do Codex já aparecem no notch. As que já estavam abertas antes da
   instalação precisam ser reiniciadas.
4. As **atualizações chegam sozinhas**: o app avisa quando tem versão nova.

**Não** tente ligar as permissões por ela, nem mexer nos Ajustes do Sistema ou no banco do TCC. Quem concede é
a pessoa, nos diálogos do macOS.

## Atualizar

O próprio app se atualiza (barra de menus › **Verificar atualizações…**). Rodar o comando do passo 2 de novo
também atualiza.

## Desinstalar

```bash
curl -fsSL https://raw.githubusercontent.com/reesoousa/boringCode/HEAD/scripts/install.sh | bash -s -- --uninstall
```

O script:

- fecha o app;
- remove **só** os hooks do boringCode de `~/.claude/settings.json` e `~/.codex/hooks.json`, guardando um backup
  `*.boringcode-backup.*` ao lado;
- apaga o script do hook e o app.

Os ajustes ficam guardados.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| "Não é possível verificar o desenvolvedor" ao abrir | Acontece com o DMG baixado pelo navegador (o `curl` não marca o arquivo). Ajustes do Sistema › Privacidade e Segurança › **Abrir mesmo assim**. |
| Nada aparece no notch | Confira se o app está rodando (`pgrep -x boringCode`). Em Macs sem notch, ele fica no topo da tela, ao centro. |
| As sessões do Claude Code não aparecem | Reinicie a sessão. Confira em Ajustes › Agentes de IA se os hooks estão instalados. |
| Arrastar janela até o notch não faz nada | Falta a permissão de Acessibilidade: o notch mostra "Precisa de permissão", e soltar a janela abre o pedido. |

Mais detalhes para pessoas: [docs/instalar.md](instalar.md). Para desenvolver no projeto: [CLAUDE.md](../CLAUDE.md).
