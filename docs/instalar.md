# Instalar o boringCode

Precisa de um Mac com **macOS 14 (Sonoma) ou mais novo**. Funciona em Apple Silicon e Intel.

1. Baixe o `boringCode-<versão>.dmg` mais recente em
   [Releases](https://github.com/reesoousa/boringCode/releases), abra e arraste o **boringCode** para
   **Aplicativos**.
2. Abra o boringCode em Aplicativos. Na primeira vez o macOS avisa que não pode verificar o app,
   porque ele ainda não passou pela notarização da Apple. Clique em **OK** (não em "Mover para o Lixo").
3. Vá em **Ajustes do Sistema › Privacidade e Segurança**, role até o fim e clique em
   **Abrir mesmo assim** ao lado de "boringCode". Confirme com sua senha ou Touch ID.
4. Abra o boringCode de novo e siga as boas-vindas. Ele aparece no notch (ou no topo da tela, se o Mac
   não tiver notch).

Isso só é preciso uma vez.

## Boas-vindas e permissões

Na primeira abertura, uma tela por recurso pergunta se você quer usar. No **sim**, o recurso liga e o
macOS já pede a permissão que ele precisa. No **Agora não**, fica desligado e dá para ligar depois nos
Ajustes do boringCode.

| Recurso | Permissão do macOS |
|---|---|
| Agentes de IA (Claude Code e Codex) | nenhuma; ao clicar numa sessão, o macOS pede **Automação** para focar o Terminal/iTerm |
| Encaixe de janelas, notificações no notch, volume e brilho | **Acessibilidade** (no macOS 27: "Controle do Dispositivo e Acesso a Dados") |
| LocalSend (trocar arquivos com o celular) | **Rede Local** |
| Espelho | **Câmera** |
| Calendário e lembretes | **Calendários** e **Lembretes** |
| Visualizador de áudio | **Gravação de áudio do sistema** |

A Acessibilidade é ligada nos Ajustes do Sistema: o boringCode abre o aviso, você liga a chave ao lado de
"boringCode" e volta. As boas-vindas seguem sozinhas.

## Atualizações

O boringCode procura versões novas sozinho e avisa quando tem uma. É só clicar em **Instalar**. Também dá
para procurar na hora pela barra de menus › **Verificar atualizações…**. Em **Ajustes › Sobre** você
escolhe se ele procura e baixa sozinho.

## Agentes de IA

Se você usa **Claude Code** ou **Codex**, o boringCode se conecta a eles (com o seu sim nas boas-vindas) e
mostra as sessões na aba **Agentes** do notch. Dá para desligar em **Ajustes › Agentes de IA**.

## Encaixe de janelas

Arraste uma janela pela barra de título até o notch e solte num layout (metades, terços, foco, quartos,
centro ou preencher). Para continuar arrastando normalmente, é só se afastar do notch.

## Desinstalar

Antes, em **Ajustes › Agentes de IA**, clique em **Remover hooks** em cada agente. Depois feche o
app pela barra de menus e apague-o de Aplicativos.
