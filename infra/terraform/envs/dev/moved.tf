##state migrations for the flat-root -> modules refactor: same
##resources, new addresses. Without these blocks terraform would
##destroy and recreate everything. Removable once applied everywhere.

##--- cv-bucket -------------------------------------------------------

moved {
  from = aws_s3_bucket.cv
  to   = module.cv_bucket.aws_s3_bucket.cv
}

moved {
  from = aws_s3_bucket_public_access_block.cv
  to   = module.cv_bucket.aws_s3_bucket_public_access_block.cv
}

moved {
  from = aws_s3_bucket_cors_configuration.cv
  to   = module.cv_bucket.aws_s3_bucket_cors_configuration.cv
}

##--- frontend-hosting ------------------------------------------------

moved {
  from = aws_s3_bucket.fe
  to   = module.frontend.aws_s3_bucket.fe
}

moved {
  from = aws_s3_bucket_public_access_block.fe
  to   = module.frontend.aws_s3_bucket_public_access_block.fe
}

moved {
  from = aws_s3_bucket_policy.fe
  to   = module.frontend.aws_s3_bucket_policy.fe
}

moved {
  from = aws_cloudfront_origin_access_control.fe
  to   = module.frontend.aws_cloudfront_origin_access_control.fe
}

moved {
  from = aws_cloudfront_distribution.fe
  to   = module.frontend.aws_cloudfront_distribution.fe
}

##--- backend-api -----------------------------------------------------

moved {
  from = aws_dynamodb_table.jobs
  to   = module.backend_api.aws_dynamodb_table.jobs
}

moved {
  from = aws_iam_role.backend_api
  to   = module.backend_api.aws_iam_role.backend_api
}

moved {
  from = aws_iam_role_policy.backend_api
  to   = module.backend_api.aws_iam_role_policy.backend_api
}

moved {
  from = aws_lambda_function.backend_api
  to   = module.backend_api.aws_lambda_function.backend_api
}

moved {
  from = aws_apigatewayv2_api.backend
  to   = module.backend_api.aws_apigatewayv2_api.backend
}

moved {
  from = aws_apigatewayv2_integration.backend_api
  to   = module.backend_api.aws_apigatewayv2_integration.backend_api
}

moved {
  from = aws_apigatewayv2_route.create_job
  to   = module.backend_api.aws_apigatewayv2_route.create_job
}

moved {
  from = aws_apigatewayv2_route.get_job
  to   = module.backend_api.aws_apigatewayv2_route.get_job
}

moved {
  from = aws_apigatewayv2_stage.backend
  to   = module.backend_api.aws_apigatewayv2_stage.backend
}

moved {
  from = aws_lambda_permission.backend_api
  to   = module.backend_api.aws_lambda_permission.backend_api
}

##--- vectorstore -----------------------------------------------------

moved {
  from = aws_vpc.vectorstore
  to   = module.vectorstore.aws_vpc.vectorstore
}

moved {
  from = aws_subnet.vectorstore_a
  to   = module.vectorstore.aws_subnet.vectorstore_a
}

moved {
  from = aws_subnet.vectorstore_b
  to   = module.vectorstore.aws_subnet.vectorstore_b
}

moved {
  from = aws_db_subnet_group.vectorstore
  to   = module.vectorstore.aws_db_subnet_group.vectorstore
}

moved {
  from = aws_security_group.vectorstore
  to   = module.vectorstore.aws_security_group.vectorstore
}

moved {
  from = aws_rds_cluster.vectorstore
  to   = module.vectorstore.aws_rds_cluster.vectorstore
}

moved {
  from = aws_rds_cluster_instance.vectorstore
  to   = module.vectorstore.aws_rds_cluster_instance.vectorstore
}

##--- cv-processing ---------------------------------------------------

moved {
  from = aws_sqs_queue.cv_events_dlq
  to   = module.cv_processing.aws_sqs_queue.cv_events_dlq
}

moved {
  from = aws_sqs_queue.cv_events
  to   = module.cv_processing.aws_sqs_queue.cv_events
}

moved {
  from = aws_sqs_queue_policy.cv_events
  to   = module.cv_processing.aws_sqs_queue_policy.cv_events
}

moved {
  from = aws_s3_bucket_notification.cv
  to   = module.cv_processing.aws_s3_bucket_notification.cv
}

moved {
  from = aws_dynamodb_table.pii_map
  to   = module.cv_processing.aws_dynamodb_table.pii_map
}

moved {
  from = aws_iam_role.step
  to   = module.cv_processing.aws_iam_role.step
}

moved {
  from = aws_iam_role_policy.step
  to   = module.cv_processing.aws_iam_role_policy.step
}

moved {
  from = aws_lambda_function.step
  to   = module.cv_processing.aws_lambda_function.step
}

moved {
  from = aws_iam_role.cv_processing_sfn
  to   = module.cv_processing.aws_iam_role.cv_processing_sfn
}

moved {
  from = aws_iam_role_policy.cv_processing_sfn
  to   = module.cv_processing.aws_iam_role_policy.cv_processing_sfn
}

moved {
  from = aws_sfn_state_machine.cv_processing
  to   = module.cv_processing.aws_sfn_state_machine.cv_processing
}

moved {
  from = aws_iam_role.start_cv_processing
  to   = module.cv_processing.aws_iam_role.start_cv_processing
}

moved {
  from = aws_iam_role_policy.start_cv_processing
  to   = module.cv_processing.aws_iam_role_policy.start_cv_processing
}

moved {
  from = aws_lambda_function.start_cv_processing
  to   = module.cv_processing.aws_lambda_function.start_cv_processing
}

moved {
  from = aws_lambda_event_source_mapping.start_cv_processing
  to   = module.cv_processing.aws_lambda_event_source_mapping.start_cv_processing
}
