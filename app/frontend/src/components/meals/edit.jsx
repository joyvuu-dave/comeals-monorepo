import Header from "../meal/header";
import LoadStatus from "../meal/load_status";
import DateBox from "../meal/date_box";
import MenuBox from "../meal/menu_box";
import CooksBox from "../meal/cooks_box";
import InfoBox from "../meal/info_box";
import AttendeesBox from "../meal/attendees_box";

const styles = {
  section: {
    margin: "1em 0 1em 0",
  },
  container: {
    marginRight: "auto",
    marginLeft: "auto",
    paddingRight: 0,
    paddingLeft: 0,
    width: "100%",
  },
};

// No observer() here: this component reads no observables itself; the
// child boxes each observe the store on their own.
const MealsEdit = () => (
  <div style={styles.container}>
    <Header />
    <LoadStatus />
    <div style={styles.container}>
      <section style={styles.section}>
        <div className="wrapper">
          <DateBox />
          <MenuBox />
          <CooksBox />
          <InfoBox />
          <AttendeesBox />
        </div>
      </section>
    </div>
  </div>
);

export default MealsEdit;
