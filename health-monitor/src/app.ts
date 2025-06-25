import express from "express";
import dotenv from "dotenv";
import { HealthCheckService } from "./health-check";
import { authMiddleware } from "./auth-middleware";

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.get("/health", authMiddleware, async (req, res) => {
    try {
        const result = await HealthCheckService.performHealthCheck();

        if (result.success) {
            res.status(200).json({
                status: "healthy",
                message: result.message,
                timestamp: new Date().toISOString(),
                details: result.details,
            });
        } else {
            res.status(500).json({
                status: "unhealthy",
                message: result.message,
                timestamp: new Date().toISOString(),
                details: result.details,
            });
        }
    } catch (error: any) {
        res.status(500).json({
            status: "error",
            message: "Unexpected error during health check",
            timestamp: new Date().toISOString(),
            error: error.message,
        });
    }
});

app.use(
    (
        err: any,
        req: express.Request,
        res: express.Response,
        next: express.NextFunction
    ) => {
        console.error("Unexpected error:", err);
        res.status(500).json({
            status: "error",
            message: "Internal server error",
            timestamp: new Date().toISOString(),
        });
    }
);

app.listen(PORT, () => {
    console.log(`MongoDB Health Check Service listening on port ${PORT}`);
    console.log(`Health check endpoint: http://localhost:${PORT}/health`);
});

export default app;
