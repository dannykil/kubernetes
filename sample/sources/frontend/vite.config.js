import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// 로컬 개발: 백엔드1은 8003, 백엔드2는 8002 (클러스터에서는 Ingress 동일 경로 사용)
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api/departments": {
        target: "http://127.0.0.1:8003",
        changeOrigin: true,
      },
      "/api/employees": {
        target: "http://127.0.0.1:8002",
        changeOrigin: true,
      },
    },
  },
});
