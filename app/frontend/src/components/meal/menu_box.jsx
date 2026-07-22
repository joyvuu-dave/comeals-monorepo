import { Component } from "react";
import { inject, observer } from "mobx-react";

import { SAVE_DEBOUNCE_MS } from "../../helpers/helpers";

const styles = {
  main: {
    gridArea: "a3",
    display: "grid",
    gridTemplateRows: "1fr 4fr",
    border: "1px solid",
  },
  text: {
    height: "100%",
    resize: "none",
    opacity: "1",
    visibility: "visible",
    fontSize: "1.25rem",
    whiteSpace: "pre-wrap",
  },
  notSaved: {
    color: "#b00020",
    fontWeight: "bold",
    alignSelf: "center",
  },
};

class DebouncedTextarea extends Component {
  constructor(props) {
    super(props);
    this.state = { value: props.value || "" };
    this.timeout = null;
    // Typed text the debounce has not delivered yet, or null.
    this.pendingValue = null;
  }

  componentDidUpdate(prevProps) {
    if (
      prevProps.value !== this.props.value &&
      this.props.value !== this.state.value
    ) {
      this.setState({ value: this.props.value || "" });
    }
  }

  componentWillUnmount() {
    // The instance is keyed to its meal, so unmount means that meal is
    // leaving the screen. Deliver any undelivered text now — dropping
    // it would lose typing, and letting the timer fire later would
    // deliver it after the callbacks' meal is gone.
    clearTimeout(this.timeout);
    if (this.pendingValue !== null) {
      this.props.onChange(this.pendingValue);
      this.pendingValue = null;
    }
  }

  handleChange = (e) => {
    var val = e.target.value;
    this.setState({ value: val });
    this.pendingValue = val;
    if (this.props.onTyping) {
      this.props.onTyping();
    }
    clearTimeout(this.timeout);
    this.timeout = setTimeout(() => {
      this.pendingValue = null;
      this.props.onChange(val);
    }, this.props.debounceTimeout || SAVE_DEBOUNCE_MS);
  };

  render() {
    return (
      <textarea
        value={this.state.value}
        onChange={this.handleChange}
        className={this.props.className}
        style={this.props.style}
        disabled={this.props.disabled}
        aria-label={this.props["aria-label"]}
      />
    );
  }
}

const MenuBox = inject("store")(
  observer(({ store }) => {
    // Bind the node at render time, and key the textarea to it. The
    // debounced flush and the unmount flush then always save to the
    // meal the text was typed on — reading store.meal at flush time
    // saved late text onto whatever meal the user had switched to.
    const meal = store.meal;
    return (
      <div style={styles.main} className="button-border-radius">
        <div className="flex space-between title">
          <h2 className="w-15">Menu</h2>
          {meal && meal.descriptionNotSaved && (
            <span style={styles.notSaved} role="status">
              Not saved — will retry
            </span>
          )}
        </div>
        <div>
          <DebouncedTextarea
            key={meal ? meal.id : "no-meal"}
            className={store.editDescriptionMode ? "" : "offwhite"}
            style={styles.text}
            value={meal && meal.description}
            onChange={(val) => store.setDescriptionOn(meal, val)}
            onTyping={() => store.noteMenuTyping(meal)}
            disabled={
              // Frozen while the next meal loads: the box shows "" until
              // the data arrives, and text typed into that emptiness would
              // overwrite the real menu that has not shown yet.
              store.mealLoading ||
              !store.editDescriptionMode ||
              (meal && meal.closed)
            }
            aria-label="Enter meal description"
          />
        </div>
      </div>
    );
  }),
);

export default MenuBox;
