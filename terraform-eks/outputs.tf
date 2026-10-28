output "cluster_name" {
  value = module.eks.cluster_name
}

output "update_kubeconfig" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "elk_private_ip" {
  value = aws_instance.elk.private_ip
}

output "elk_public_ip" {
  value = aws_instance.elk.public_ip
}
