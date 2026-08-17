            - name: clickhouse-backup
              image: "altinity/clickhouse-backup:2.6.0"
              args: ["server"]
              resources:
                requests:
                  cpu: "100m"
                  memory: "256Mi"
                limits:
                  cpu: "500m"
                  memory: "512Mi"
              env:
                - name: LOG_LEVEL
                  value: "info"
                - name: REMOTE_STORAGE
                  value: "s3"
                - name: S3_BUCKET
                  valueFrom:
                    configMapKeyRef:
                      name: clickhouse-backup-config
                      key: S3_BUCKET
                - name: S3_REGION
                  valueFrom:
                    configMapKeyRef:
                      name: clickhouse-backup-config
                      key: S3_REGION
                - name: S3_PATH
                  # Must match the cluster's own S3 prefix: the backup IAM role is
                  # scoped to s3://<bucket>/<cluster>/*, so any other path is denied.
                  value: "__CLUSTER__"
              ports:
                - name: backup-rest
                  containerPort: 7171
