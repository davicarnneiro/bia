#!/bin/bash
set -euo pipefail

# =============================================================================
# ecs-deploy.sh - Deploy, rollback e listagem de versoes no ECS
# Projeto BIA | Formacao AWS
#
# Uso:
#   ./scripts/ecs-deploy.sh deploy
#   ./scripts/ecs-deploy.sh list
#   ./scripts/ecs-deploy.sh rollback
#   ./scripts/ecs-deploy.sh rollback <numero-da-revisao>
# =============================================================================

# =============================================================================
# CONFIGURACAO DO AMBIENTE
# Para trocar de ambiente, altere as variaveis abaixo:
#   Sem ALB:  CLUSTER="cluster-bia"     SERVICE="service-bia"     TASK_FAMILY="task-def-bia"
#   Com ALB:  CLUSTER="cluster-bia-alb" SERVICE="service-bia-alb" TASK_FAMILY="task-def-bia-alb"
# =============================================================================
CLUSTER="cluster-bia-alb"
SERVICE="service-bia-alb"
TASK_FAMILY="task-def-bia-alb"
CONTAINER_NAME="bia"
AWS_REGION="us-east-1"
ECR_REPO_NAME="bia"

# =============================================================================
# CORES
# =============================================================================
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

# =============================================================================
# HELPERS
# =============================================================================
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
erro()    { echo -e "${RED}[ERRO]${NC} $1" >&2; }
passo()   { echo -e "\n${BOLD}${CYAN}>> $1${NC}"; }

check_deps() {
    for cmd in aws docker git jq; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            erro "Dependencia nao encontrada: $cmd"
            exit 1
        fi
    done
}

get_ecr_uri() {
    aws ecr describe-repositories \
        --repository-names "$ECR_REPO_NAME" \
        --region "$AWS_REGION" \
        --query "repositories[0].repositoryUri" \
        --output text
}

get_active_revision() {
    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$AWS_REGION" \
        --query "services[0].taskDefinition" \
        --output text \
    | sed 's/.*://'
}

get_image_tag() {
    local revision=$1
    aws ecs describe-task-definition \
        --task-definition "${TASK_FAMILY}:${revision}" \
        --region "$AWS_REGION" \
        --output json \
    | jq -r --arg name "$CONTAINER_NAME" \
        '.taskDefinition.containerDefinitions[] | select(.name == $name) | .image' \
    | sed 's/.*://'
}

get_registered_at() {
    local revision=$1
    aws ecs describe-task-definition \
        --task-definition "${TASK_FAMILY}:${revision}" \
        --region "$AWS_REGION" \
        --output json \
    | jq -r '.taskDefinition.registeredAt' \
    | sed 's/T/ /' \
    | sed 's/\..*//'
}

# =============================================================================
# COMANDO: list
# =============================================================================
cmd_list() {
    passo "Revisoes disponiveis - ${TASK_FAMILY}"

    local arns
    arns=$(aws ecs list-task-definitions \
        --family-prefix "$TASK_FAMILY" \
        --region "$AWS_REGION" \
        --status ACTIVE \
        --query "taskDefinitionArns" \
        --output json)

    local total
    total=$(echo "$arns" | jq length)

    if [ "$total" -eq 0 ]; then
        warn "Nenhuma revisao encontrada para: $TASK_FAMILY"
        return 0
    fi

    local active
    active=$(get_active_revision)

    info "Revisao ativa no service '${SERVICE}': ${BOLD}${active}${NC}"
    echo ""
    printf "${BOLD}%-10s %-20s %-25s %-10s${NC}\n" "REVISAO" "TAG / HASH" "REGISTRADA EM" "STATUS"
    printf -- "------------------------------------------------------------------------\n"

    echo "$arns" | jq -r ".[]" | tac | while IFS= read -r arn; do
        local rev
        rev=$(echo "$arn" | sed "s/.*://")

        local tag
        tag=$(get_image_tag "$rev")

        local reg
        reg=$(get_registered_at "$rev")

        if [ "$rev" = "$active" ]; then
            printf "${GREEN}%-10s %-20s %-25s %-10s${NC}\n" "$rev" "$tag" "$reg" "<<< ATIVA"
        else
            printf "%-10s %-20s %-25s\n" "$rev" "$tag" "$reg"
        fi
    done

    echo ""
}

# =============================================================================
# COMANDO: deploy
# =============================================================================
cmd_deploy() {
    passo "Deploy - ${CLUSTER} / ${SERVICE}"

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        erro "Nao e um repositorio git."
        exit 1
    fi

    local hash
    hash=$(git rev-parse --short=7 HEAD)
    info "Commit hash: ${BOLD}${hash}${NC}"

    local ecr_uri
    ecr_uri=$(get_ecr_uri)
    local ecr_host
    ecr_host=$(echo "$ecr_uri" | cut -d"/" -f1)
    info "ECR: $ecr_uri"

    passo "Login no ECR..."
    aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "$ecr_host"
    ok "Login realizado."

    local project_root
    project_root=$(git rev-parse --show-toplevel)

    passo "Build da imagem..."
    docker build -t bia "$project_root"
    docker tag bia:latest "${ecr_uri}:latest"
    docker tag bia:latest "${ecr_uri}:${hash}"
    ok "Build: ${ecr_uri}:${hash}"

    passo "Push para o ECR..."
    docker push "${ecr_uri}:latest"
    docker push "${ecr_uri}:${hash}"
    ok "Push concluido."

    passo "Registrando nova revisao da task definition..."
    local task_json
    task_json=$(aws ecs describe-task-definition \
        --task-definition "$TASK_FAMILY" \
        --region "$AWS_REGION" \
        --query "taskDefinition" \
        --output json)

    local new_image="${ecr_uri}:${hash}"
    local new_task
    new_task=$(echo "$task_json" | jq \
        --arg img "$new_image" \
        --arg cname "$CONTAINER_NAME" \
        '.containerDefinitions |= map(if .name == $cname then .image = $img else . end)
         | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

    local new_rev
    new_rev=$(aws ecs register-task-definition \
        --region "$AWS_REGION" \
        --cli-input-json "$new_task" \
        --query "taskDefinition.revision" \
        --output text)
    ok "Nova revisao: ${TASK_FAMILY}:${new_rev}"

    passo "Atualizando service..."
    aws ecs update-service \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "${TASK_FAMILY}:${new_rev}" \
        --region "$AWS_REGION" \
        --output json > /dev/null
    ok "Service atualizado."

    passo "Aguardando estabilizacao (pode levar alguns minutos)..."
    if aws ecs wait services-stable \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$AWS_REGION"
    then
        ok "Deploy concluido com sucesso!"
        echo ""
        echo -e "  Cluster  : $CLUSTER"
        echo -e "  Service  : $SERVICE"
        echo -e "  Revisao  : ${TASK_FAMILY}:${new_rev}"
        echo -e "  Imagem   : ${ecr_uri}:${hash}"
    else
        erro "Service nao estabilizou. Verifique:"
        echo "  aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $AWS_REGION"
        exit 1
    fi
}

# =============================================================================
# COMANDO: rollback
# =============================================================================
cmd_rollback() {
    local target="${1:-}"

    passo "Rollback - ${CLUSTER} / ${SERVICE}"

    cmd_list

    local active
    active=$(get_active_revision)

    if [ -z "$target" ]; then
        echo -e "${YELLOW}Digite o numero da revisao para rollback (ativa: ${active}):${NC}"
        read -r -p "Revisao: " target
    fi

    if [ -z "$target" ]; then
        erro "Nenhuma revisao informada. Cancelado."
        exit 1
    fi

    if ! echo "$target" | grep -qE "^[0-9]+$"; then
        erro "Revisao invalida: '${target}'. Informe apenas o numero."
        exit 1
    fi

    if ! aws ecs describe-task-definition \
        --task-definition "${TASK_FAMILY}:${target}" \
        --region "$AWS_REGION" > /dev/null 2>&1
    then
        erro "Revisao ${target} nao encontrada em ${TASK_FAMILY}."
        exit 1
    fi

    local tag
    tag=$(get_image_tag "$target")

    echo ""
    warn "Voce esta prestes a reverter para:"
    echo "  Revisao : ${TASK_FAMILY}:${target}"
    echo "  Imagem  : ${tag}"
    echo ""
    read -r -p "Confirmar rollback? [s/N]: " confirm

    if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
        info "Rollback cancelado."
        exit 0
    fi

    passo "Revertendo service para revisao ${target}..."
    aws ecs update-service \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "${TASK_FAMILY}:${target}" \
        --region "$AWS_REGION" \
        --output json > /dev/null
    ok "Service atualizado."

    passo "Aguardando estabilizacao (pode levar alguns minutos)..."
    if aws ecs wait services-stable \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$AWS_REGION"
    then
        ok "Rollback concluido com sucesso!"
        echo ""
        echo -e "  Cluster  : $CLUSTER"
        echo -e "  Service  : $SERVICE"
        echo -e "  Revisao  : ${TASK_FAMILY}:${target}"
        echo -e "  Imagem   : ${tag}"
    else
        erro "Service nao estabilizou. Verifique:"
        echo "  aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $AWS_REGION"
        exit 1
    fi
}

# =============================================================================
# MENU DE AJUDA
# =============================================================================
cmd_help() {
    echo -e "${BOLD}ecs-deploy.sh${NC} - Deploy, rollback e listagem de versoes no ECS"
    echo ""
    echo "Uso:"
    echo "  $0 deploy                 Build + push + deploy da revisao atual do git"
    echo "  $0 list                   Lista todas as revisoes disponiveis"
    echo "  $0 rollback               Rollback interativo"
    echo "  $0 rollback <revisao>     Rollback direto para a revisao informada"
    echo ""
    echo "Ambiente atual:"
    echo "  Cluster    : $CLUSTER"
    echo "  Service    : $SERVICE"
    echo "  Task Def   : $TASK_FAMILY"
    echo "  Regiao     : $AWS_REGION"
}

# =============================================================================
# MAIN
# =============================================================================
check_deps

CMD="${1:-}"

case "$CMD" in
    deploy)
        cmd_deploy
        ;;
    list)
        cmd_list
        ;;
    rollback)
        shift || true
        cmd_rollback "${1:-}"
        ;;
    "")
        cmd_help
        ;;
    *)
        erro "Comando desconhecido: '$CMD'"
        echo "Use: $0 [deploy|list|rollback]"
        exit 1
        ;;
esac
