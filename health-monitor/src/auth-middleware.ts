import { Request, Response, NextFunction } from "express";
import dotenv from "dotenv";

dotenv.config();

export interface AuthenticatedRequest extends Request {
    isAuthenticated?: boolean;
}

export const authMiddleware = (
    req: AuthenticatedRequest,
    res: Response,
    next: NextFunction
) => {
    const expectedToken = process.env.HEALTH_CHECK_TOKEN;

    if (!expectedToken) {
        console.error(
            "HEALTH_CHECK_TOKEN not configured in environment variables"
        );
        return res.status(500).json({
            status: "error",
            message: "Authentication not properly configured",
            timestamp: new Date().toISOString(),
        });
    }

    const token =
        req.headers.authorization?.replace("Bearer ", "") ||
        (req.headers["x-api-key"] as string) ||
        (req.query.token as string);

    if (!token) {
        return res.status(401).json({
            status: "unauthorized",
            message: "Authentication token required.",
            timestamp: new Date().toISOString(),
        });
    }

    if (token !== expectedToken) {
        return res.status(403).json({
            status: "forbidden",
            message: "Invalid authentication token",
            timestamp: new Date().toISOString(),
        });
    }

    req.isAuthenticated = true;
    next();
};
