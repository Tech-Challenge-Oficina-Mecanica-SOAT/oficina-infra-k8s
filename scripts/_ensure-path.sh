# Garante aws/helm no PATH e a regiao da AWS quando um script roda direto
# (./scripts/x.sh), fora do make (que ja cuida dos dois no proprio
# Makefile). Sem isso, kubectl falha com "executable aws not found" ao
# tentar renovar credenciais via client-go exec credential plugin, e
# comandos aws sem --region explicito falham com "NoRegion".
#
# Formato POSIX (":", "/c/...") e suficiente aqui: diferente do Makefile
# (onde o PATH herdado por make.exe ja vem em formato nativo do Windows e
# misturar POSIX quebra a reconversao pro kubectl.exe), um script bash
# rodado diretamente mantém o PATH inteiro em formato POSIX internamente,
# entao appendar mais POSIX aqui nao introduz a mesma inconsistencia.
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/_ensure-path.sh"

if ! command -v aws >/dev/null 2>&1; then
  export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
fi

if ! command -v helm >/dev/null 2>&1; then
  HELM_FALLBACK=$(ls -d /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Helm.Helm_Microsoft.Winget.Source_*/windows-amd64 2>/dev/null | head -1)
  if [ -n "$HELM_FALLBACK" ]; then
    export PATH="$PATH:$HELM_FALLBACK"
  fi
fi

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export MSYS_NO_PATHCONV=1
