import { Link } from "react-router";

// What the app shows at an address that is not one of its pages. The
// server answers such an address with a 404 and its plain 404 page
// (public/404.html), so the app shows this only when it moves to a bad
// address on its own, without asking the server.
export default function NotFound() {
  return (
    <div>
      <header className="flex space-between header">
        <h2 className="pad-l-sm">Comeals</h2>
      </header>
      {/* The same space under the header as the login page leaves. */}
      <div style={{ padding: "1rem 15px" }}>
        <h3>Page not found</h3>
        <p>There is no page at this address.</p>
        <Link to="/">Go to Comeals</Link>
      </div>
    </div>
  );
}
