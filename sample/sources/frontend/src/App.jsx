import { useEffect, useState } from "react";

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText}`);
  }
  return res.json();
}

export default function App() {
  const [deptState, setDeptState] = useState({ loading: true, error: null, data: null });
  const [empState, setEmpState] = useState({ loading: true, error: null, data: null });

  useEffect(() => {
    let cancelled = false;
    fetchJson("/api/departments")
      .then((data) => {
        if (!cancelled) setDeptState({ loading: false, error: null, data });
      })
      .catch((e) => {
        if (!cancelled) setDeptState({ loading: false, error: String(e.message), data: null });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    fetchJson("/api/employees")
      .then((data) => {
        if (!cancelled) setEmpState({ loading: false, error: null, data });
      })
      .catch((e) => {
        if (!cancelled) setEmpState({ loading: false, error: String(e.message), data: null });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="page">
      <header className="header">
        <h1>샘플 대시보드</h1>
        <p className="sub">
          회사·부서는 백엔드1, 직원은 백엔드2 API를 호출합니다. Ingress 사용 시 동일 호스트의{" "}
          <code>/api/departments</code>, <code>/api/employees</code>로 연결됩니다.
        </p>
      </header>

      <main className="grid">
        <section className="card">
          <h2>회사 / 부서 (백엔드1)</h2>
          {deptState.loading && <p className="muted">불러오는 중…</p>}
          {deptState.error && <p className="error">{deptState.error}</p>}
          {!deptState.loading && !deptState.error && deptState.data && (
            <ul className="list">
              {deptState.data.items.map((row) => (
                <li key={row.id}>
                  <span className="title">
                    {row.company} — {row.department}
                  </span>
                  <span className="meta">{row.location}</span>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="card">
          <h2>직원 (백엔드2)</h2>
          {empState.loading && <p className="muted">불러오는 중…</p>}
          {empState.error && <p className="error">{empState.error}</p>}
          {!empState.loading && !empState.error && empState.data && (
            <ul className="list list-dense">
              {empState.data.items.map((row) => (
                <li key={row.id}>
                  <span className="title">
                    {row.name} · {row.role}
                  </span>
                  <span className="meta">
                    {row.company} / {row.department}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </main>
    </div>
  );
}
