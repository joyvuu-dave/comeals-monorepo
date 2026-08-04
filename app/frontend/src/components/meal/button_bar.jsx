import { useLocation, useNavigate } from "react-router";

const styles = {
  main: {
    display: "flex",
    justifyContent: "space-between",
  },
};

function ButtonBar() {
  const navigate = useNavigate();
  const location = useLocation();

  function toggleHistory() {
    if (location.pathname.includes("/history")) {
      navigate(location.pathname.split("/history")[0]);
    } else {
      navigate(`${location.pathname}history/`);
    }
  }

  return (
    <div style={styles.main} className="button-border-radius">
      <button className="button-link text-secondary" onClick={toggleHistory}>
        history
      </button>
    </div>
  );
}

export default ButtonBar;
