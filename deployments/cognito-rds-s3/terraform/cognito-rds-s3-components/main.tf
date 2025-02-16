provider "aws" {
  alias = "aws"
}

provider "aws" {
  alias = "virginia"
}

locals {
  katib_chart_vanilla  = "${var.kf_helm_repo_path}/charts/apps/katib/vanilla"
  katib_chart_rds  = "${var.kf_helm_repo_path}/charts/apps/katib/katib-external-db-with-kubeflow"

  kfp_chart_vanilla  = "${var.kf_helm_repo_path}/charts/apps/kubeflow-pipelines/vanilla"
  kfp_chart_rds_only  = "${var.kf_helm_repo_path}/charts/apps/kubeflow-pipelines/rds-only"
  kfp_chart_s3_only  = "${var.kf_helm_repo_path}/charts/apps/kubeflow-pipelines/s3-only"
  kfp_chart_rds_and_s3  = "${var.kf_helm_repo_path}/charts/apps/kubeflow-pipelines/rds-s3"

  secrets_manager_chart_rds = "${var.kf_helm_repo_path}/charts/common/aws-secrets-manager/rds-only"
  secrets_manager_chart_s3 = "${var.kf_helm_repo_path}/charts/common/aws-secrets-manager/s3-only"
  secrets_manager_chart_rds_s3 = "${var.kf_helm_repo_path}/charts/common/aws-secrets-manager/rds-s3"

  kfp_chart_map = {
    (local.kfp_chart_vanilla) = !var.use_rds && !var.use_s3,
    (local.kfp_chart_rds_only) = var.use_rds && !var.use_s3,
    (local.kfp_chart_s3_only) = !var.use_rds && var.use_s3,
    (local.kfp_chart_rds_and_s3) = var.use_rds && var.use_s3
  }

  secrets_manager_chart_map = {
    (local.secrets_manager_chart_rds) = var.use_rds && !var.use_s3,
    (local.secrets_manager_chart_s3) = !var.use_rds && var.use_s3,
    (local.secrets_manager_chart_rds_s3) = var.use_rds && var.use_s3
  }

  katib_chart = var.use_rds ? local.katib_chart_rds : local.katib_chart_vanilla
  kfp_chart = [for k,v in local.kfp_chart_map : k if v == true][0]
  secrets_manager_chart = [for k,v in local.secrets_manager_chart_map : k if v == true][0]
}

resource "kubernetes_namespace" "kubeflow" {
  metadata {
    labels = {
      control-plane = "kubeflow"
      istio-injection = "enabled"
    }

    name = "kubeflow"
  }
}

module "kubeflow_secrets_manager_irsa" {
  source            = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/irsa?ref=v4.12.1"
  kubernetes_namespace = kubernetes_namespace.kubeflow.metadata[0].name
  create_kubernetes_namespace = false
  create_kubernetes_service_account = true
  kubernetes_service_account        = "kubeflow-secrets-manager-sa"
  irsa_iam_role_name = format("%s-%s-%s-%s", "kf-secrets-manager", "irsa", var.addon_context.eks_cluster_id, var.addon_context.aws_region_name)
  irsa_iam_policies                 = ["arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess", "arn:aws:iam::aws:policy/SecretsManagerReadWrite"]
  irsa_iam_role_path                = var.addon_context.irsa_iam_role_path
  irsa_iam_permissions_boundary     = var.addon_context.irsa_iam_permissions_boundary
  eks_cluster_id                    = var.addon_context.eks_cluster_id
  eks_oidc_provider_arn             = var.addon_context.eks_oidc_provider_arn
}

resource "random_password" "db_password" {
  count = var.generate_db_password ? 1 : 0
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

module "rds" {
  count = var.use_rds ? 1 : 0
  source            = "../../../../iaac/terraform/aws-infra/rds"
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  security_group_id = var.security_group_id
  db_name = var.db_name
  db_username = var.db_username
  db_password = coalesce(var.db_password, try(random_password.db_password[0].result, null))
  db_class = var.db_class
  db_allocated_storage = var.db_allocated_storage
  backup_retention_period = var.backup_retention_period
  storage_type = var.storage_type
  deletion_protection = var.deletion_protection
  max_allocated_storage = var.max_allocated_storage
  publicly_accessible = var.publicly_accessible
  multi_az = var.multi_az
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
}

module "s3" {
  count = var.use_s3 ? 1 : 0
  source            = "../../../../iaac/terraform/aws-infra/s3"
  force_destroy_bucket = var.force_destroy_s3_bucket
  minio_aws_access_key_id = var.minio_aws_access_key_id
  minio_aws_secret_access_key = var.minio_aws_secret_access_key
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
}

module "subdomain" {
  count = var.use_cognito && var.create_subdomain ? 1 : 0
  source            = "../../../../iaac/terraform/aws-infra/subdomain"
  aws_route53_root_zone_name = var.aws_route53_root_zone_name
  aws_route53_subdomain_zone_name = var.aws_route53_subdomain_zone_name
}

module "cognito" {
  count = var.use_cognito ? 1 : 0
  source            = "../../../../iaac/terraform/aws-infra/cognito"
  cognito_user_pool_name = var.cognito_user_pool_name
  aws_route53_subdomain_zone_name = var.aws_route53_subdomain_zone_name

  providers = {
    aws = aws
    aws.virginia = aws.virginia
  }

  depends_on = [module.subdomain]
}

module "filter_secrets_manager_set_values" {
  source            = "../../../../iaac/terraform/utils/set-values-filter"
  set_values = {
    "rds.secretName" = try(module.rds[0].rds_secret_name, null),
    "s3.secretName" = try(module.s3[0].s3_secret_name, null),
  }
}

module "secrets_manager" {
  count = var.use_rds || var.use_s3 ? 1 : 0
  source            = "../../../../iaac/terraform/common/aws-secrets-manager"
  helm_config = {
    chart = local.secrets_manager_chart
    set = module.filter_secrets_manager_set_values.set_values
  }

  addon_context = var.addon_context
  depends_on = [kubernetes_namespace.kubeflow, module.rds, module.s3]
}

module "kubeflow_issuer" {
  source            = "../../../../iaac/terraform/common/kubeflow-issuer"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/kubeflow-issuer"
  }

  addon_context = var.addon_context
  depends_on = [kubernetes_namespace.kubeflow]
}

module "kubeflow_istio" {
  source            = "../../../../iaac/terraform/common/istio"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/istio"
  }
  addon_context = var.addon_context
  depends_on = [module.kubeflow_issuer]
}

module "kubeflow_dex" {
  count = var.use_cognito ? 0 : 1
  source            = "../../../../iaac/terraform/common/dex"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/dex"
  }
  addon_context = var.addon_context
  depends_on = [module.kubeflow_istio]
}

module "kubeflow_oidc_authservice" {
  count = var.use_cognito ? 0 : 1
  source            = "../../../../iaac/terraform/common/oidc-authservice"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/oidc-authservice" 
  }
  addon_context = var.addon_context
  depends_on = [module.kubeflow_dex]
}

module "ingress_cognito" {
  count = var.use_cognito ? 1 : 0
  source            = "../../../../iaac/terraform/common/ingress/cognito"
  aws_route53_subdomain_zone_name = var.aws_route53_subdomain_zone_name
  cluster_name = var.addon_context.eks_cluster_id
  cognito_user_pool_arn = module.cognito[0].user_pool_arn
  cognito_app_client_id = module.cognito[0].app_client_id
  cognito_user_pool_domain = module.cognito[0].user_pool_domain
  load_balancer_scheme = var.load_balancer_scheme

  depends_on = [module.kubeflow_istio, module.cognito]
}

module "kubeflow_aws_authservice" {
  count = var.use_cognito ? 1 : 0
  source            = "../../../../iaac/terraform/common/aws-authservice"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/aws-authservice" 
    set = [
      {
        name = "LOGOUT_URL"
        value = module.cognito[0].logout_url
      }
    ]
  }
  addon_context = var.addon_context
  depends_on = [module.ingress_cognito]
}

module "kubeflow_knative_serving" {
  source            = "../../../../iaac/terraform/common/knative-serving"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/knative-serving"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_oidc_authservice, module.kubeflow_aws_authservice]
}

module "kubeflow_cluster_local_gateway" {
  source            = "../../../../iaac/terraform/common/cluster-local-gateway"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/cluster-local-gateway"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_knative_serving]
}

module "kubeflow_knative_eventing" {
  source            = "../../../../iaac/terraform/common/knative-eventing"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/knative-eventing"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_cluster_local_gateway]
}

module "kubeflow_roles" {
  source            = "../../../../iaac/terraform/common/kubeflow-roles"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/kubeflow-roles"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_knative_eventing]
}

module "kubeflow_istio_resources" {
  source            = "../../../../iaac/terraform/common/kubeflow-istio-resources"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/kubeflow-istio-resources"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_roles]
}

module "filter_kfp_set_values" {
  source            = "../../../../iaac/terraform/utils/set-values-filter"
  set_values = {
    "rds.dbHost" = try(module.rds[0].rds_endpoint, null),
    "s3.bucketName" = try(module.s3[0].s3_bucket_name ,null),
    "s3.minioServiceRegion" = coalesce(var.minio_service_region, var.addon_context.aws_region_name)
    "rds.mlmdDb" = var.mlmdb_name,
    "s3.minioServiceHost" = var.minio_service_host
  }
}

module "kubeflow_pipelines" {
  source            = "../../../../iaac/terraform/apps/kubeflow-pipelines"
  helm_config = {
    chart = local.kfp_chart
    set = module.filter_kfp_set_values.set_values
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_istio_resources, module.secrets_manager]
}

module "kubeflow_kserve" {
  source            = "../../../../iaac/terraform/common/kserve"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/kserve"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_pipelines]
}

module "kubeflow_models_web_app" {
  source            = "../../../../iaac/terraform/apps/models-web-app"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/models-web-app"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_kserve]
}

module "kubeflow_katib" {
  source            = "../../../../iaac/terraform/apps/katib"
  helm_config = {
    chart = local.katib_chart
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_models_web_app]
}

module "kubeflow_central_dashboard" {
  source            = "../../../../iaac/terraform/apps/central-dashboard"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/central-dashboard"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_katib]
}

module "kubeflow_admission_webhook" {
  source            = "../../../../iaac/terraform/apps/admission-webhook"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/admission-webhook"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_central_dashboard]
}

module "kubeflow_notebook_controller" {
  source            = "../../../../iaac/terraform/apps/notebook-controller"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/notebook-controller"
    set = [
      {
        name = "cullingPolicy.cullIdleTime",
        value = var.notebook_cull_idle_time
      },
      {
        name = "cullingPolicy.enableCulling",
        value = var.notebook_enable_culling
      },
      {
        name = "cullingPolicy.idlenessCheckPeriod",
        value= var.notebook_idleness_check_period
      }
    ]
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_admission_webhook]
}

module "kubeflow_jupyter_web_app" {
  source            = "../../../../iaac/terraform/apps/jupyter-web-app"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/jupyter-web-app"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_notebook_controller]
}

module "kubeflow_profiles_and_kfam" {
  source            = "../../../../iaac/terraform/apps/profiles-and-kfam"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/profiles-and-kfam"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_jupyter_web_app]
}

module "kubeflow_volumes_web_app" {
  source            = "../../../../iaac/terraform/apps/volumes-web-app"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/volumes-web-app"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_profiles_and_kfam]
}

module "kubeflow_tensorboards_web_app" {
  source            = "../../../../iaac/terraform/apps/tensorboards-web-app"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/tensorboards-web-app"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_volumes_web_app]
}

module "kubeflow_tensorboard_controller" {
  source            = "../../../../iaac/terraform/apps/tensorboard-controller"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/tensorboard-controller"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_tensorboards_web_app]
}

module "kubeflow_training_operator" {
  source            = "../../../../iaac/terraform/apps/training-operator"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/apps/training-operator"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_tensorboard_controller]
}

module "kubeflow_aws_telemetry" {
  count = var.enable_aws_telemetry ? 1 : 0
  source            = "../../../../iaac/terraform/common/aws-telemetry"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/aws-telemetry"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_training_operator]
}

module "kubeflow_user_namespace" {
  source            = "../../../../iaac/terraform/common/user-namespace"
  helm_config = {
    chart = "${var.kf_helm_repo_path}/charts/common/user-namespace"
  }  
  addon_context = var.addon_context
  depends_on = [module.kubeflow_aws_telemetry]
}

module "ack_sagemaker" {
  source            = "../../../../iaac/terraform/common/ack-sagemaker-controller"
  addon_context = var.addon_context
}