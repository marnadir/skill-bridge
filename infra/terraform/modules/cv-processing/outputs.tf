output "state_machine_arn" {
  description = "ARN of the cv-processing state machine"
  value       = aws_sfn_state_machine.cv_processing.arn
}
