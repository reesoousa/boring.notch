# Instalar o boringCode (versão de teste)

Precisa de um Mac com **macOS 14 (Sonoma) ou mais novo**. Funciona em Apple Silicon e Intel.

1. Abra o arquivo `boringCode-<versão>.dmg` e arraste o **boringCode** para **Aplicativos**.
2. Abra o boringCode em Aplicativos. Na primeira vez o macOS avisa que não pode verificar o app,
   porque esta versão de teste ainda não passou pela Apple. Clique em **OK** (não em "Mover para o Lixo").
3. Vá em **Ajustes do Sistema › Privacidade e Segurança**, role até o fim e clique em
   **Abrir mesmo assim** ao lado de "boringCode". Confirme com sua senha ou Touch ID.
4. Abra o boringCode de novo. Pronto: ele aparece no notch (ou no topo da tela, se o Mac não tiver notch).

Isso só é preciso uma vez.

## Permissões

O app pede algumas permissões conforme você usa. Todas são opcionais:

- **Acessibilidade** — controles de volume/brilho no notch.
- **Automação (Terminal/iTerm)** — o clique numa sessão de agente de IA volta para a aba certa.
- **Calendário, câmera, microfone** — só se você ligar esses recursos.

## Agentes de IA

Se você usa **Claude Code** ou **Codex**, o boringCode se conecta sozinho a eles e mostra as sessões
na aba **Agentes** do notch. Dá para desligar em **Ajustes › Agentes de IA**.

## Desinstalar

Antes, em **Ajustes › Agentes de IA**, clique em **Remover hooks** em cada agente. Depois feche o
app pela barra de menus e apague-o de Aplicativos.
