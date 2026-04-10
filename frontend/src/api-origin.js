/**
 * S3 웹사이트에서만 사용: API(ALB) 베이스 URL.
 * 배포 파이프라인에서 Ingress 확정 후 `k8s/scripts/sync-s3-endpoints-from-ingress.sh`가
 * 이 객체를 S3에 덮어씀. Terraform은 해당 S3 객체의 내용 변경을 무시함.
 * CloudFront 사용 시에는 상대 경로 /api/* 만 쓰므로 보통 빈 문자열로 둠.
 */
window.__TICKETING_API_ORIGIN__ = window.__TICKETING_API_ORIGIN__ || '';
