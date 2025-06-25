import { MongoClient, MongoClientOptions } from "mongodb";
import dotenv from "dotenv";

dotenv.config();

interface HealthCheckResult {
    success: boolean;
    message: string;
    details?: any;
}

export class HealthCheckService {
    private static readonly TIMEOUT_MS = 10000;

    private static getConnectionConfig() {
        const {
            MONGODB_HOST,
            MONGODB_PORT,
            MONGODB_DATABASE,
            MONGODB_USER,
            MONGODB_PASSWORD,
            MONGODB_AUTH_DB,
        } = process.env;

        if (
            !MONGODB_HOST ||
            !MONGODB_PORT ||
            !MONGODB_DATABASE ||
            !MONGODB_USER ||
            !MONGODB_PASSWORD ||
            !MONGODB_AUTH_DB
        ) {
            throw new Error("Missing required MongoDB environment variables");
        }

        const uri = `mongodb://${MONGODB_HOST}:${parseInt(MONGODB_PORT)}`;

        const tlsOptions = process.env.MONGODB_ENABLE_TLS
            ? { tls: true, tlsAllowInvalidCertificates: true }
            : {};

        const options: MongoClientOptions = {
            auth: {
                username: MONGODB_USER,
                password: MONGODB_PASSWORD,
            },
            authSource: MONGODB_AUTH_DB,
            directConnection: true,
            serverSelectionTimeoutMS: this.TIMEOUT_MS,
            socketTimeoutMS: this.TIMEOUT_MS,
            connectTimeoutMS: this.TIMEOUT_MS,
            ...tlsOptions,
        };

        return { uri, options, database: MONGODB_DATABASE };
    }

    static async performHealthCheck(): Promise<HealthCheckResult> {
        let client: MongoClient | null = null;

        try {
            const { uri, options, database } = this.getConnectionConfig();

            client = new MongoClient(uri, options);

            await client.connect();

            const pingResult = await client.db(database).admin().ping();

            if (pingResult.ok !== 1) {
                throw new Error("Ping command failed");
            }

            try {
                const replicaStatus = await client
                    .db(database)
                    .admin()
                    .command({ replSetGetStatus: 1 });

                const currentNodeInfo = replicaStatus.members?.find(
                    (member: any) => member.self === true
                );

                if (!currentNodeInfo || currentNodeInfo.health !== 1) {
                    throw new Error(
                        `Current node health is not optimal. State: ${
                            currentNodeInfo?.stateStr || "unknown"
                        }`
                    );
                }

                const hasPrimary = replicaStatus.members?.some(
                    (member: any) => member.stateStr === "PRIMARY"
                );
                if (!hasPrimary) {
                    throw new Error("No primary node found in replica set");
                }

                this.checkReplicaConnectivity(replicaStatus);

                return {
                    success: true,
                    message:
                        "MongoDB health check passed - node is healthy and connected to replica set",
                    details: {
                        replicaSet: replicaStatus.set,
                        nodeState: currentNodeInfo.stateStr,
                        nodeHealth: currentNodeInfo.health,
                        hasPrimary,
                    },
                };
            } catch (replicaError: any) {
                const serverStatus = await client
                    .db(database)
                    .admin()
                    .command({ serverStatus: 1 });

                if (serverStatus.repl) {
                    throw replicaError;
                } else {
                    return {
                        success: true,
                        message:
                            "MongoDB health check passed - standalone instance is healthy",
                        details: {
                            instanceType: "standalone",
                            uptime: serverStatus.uptime,
                        },
                    };
                }
            }
        } catch (error: any) {
            return {
                success: false,
                message: `MongoDB health check failed: ${error.message}`,
                details: {
                    error: error.message,
                    code: error.code,
                },
            };
        } finally {
            if (client) {
                try {
                    await client.close();
                } catch (closeError) {
                    console.error("Error closing MongoDB client:", closeError);
                }
            }
        }
    }

    private static checkReplicaConnectivity(replicaStatus: any) {
        const members = replicaStatus.members || [];
        const disconnectedReplicas: string[] = [];

        for (const member of members) {
            if (member.self) continue;

            if (member.health !== 1 || member.state === 8) {
                disconnectedReplicas.push(
                    `${member.name} (${member.stateStr})`
                );
            }
        }

        if (disconnectedReplicas.length > 0) {
            throw new Error(
                `Replica connectivity issues: ${disconnectedReplicas.join(
                    ", "
                )}`
            );
        }
    }
}
