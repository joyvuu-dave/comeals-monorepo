import toastStore from "../stores/toast_store";

export default function handleAxiosError(error, options) {
  var silent = options && options.silent;
  if (error.response) {
    var data = error.response.data;
    if (data.message) {
      var toastType = data.type === "warning" ? "warning" : "error";
      if (silent) {
        console.error(data.message);
      } else {
        toastStore.replaceAll(data.message, toastType);
      }
      return toastType;
    } else {
      // An answer with no sentence is a page the app did not write. During
      // a deploy Heroku answers 503 with its maintenance page, whose title
      // is "Offline for maintenance".
      console.error("Bad response from server", error);
      var maintenance =
        error.response.status === 503 &&
        typeof data === "string" &&
        /maintenance/i.test(data);
      var sentence = maintenance
        ? "Comeals is being updated. Please try again in a minute."
        : "Comeals could not do that just now. Please try again in a minute.";
      var type = maintenance ? "warning" : "error";
      if (!silent) {
        toastStore.replaceAll(sentence, type);
      }
      return type;
    }
  } else if (error.request) {
    if (silent) {
      console.error("Error: no response received from server.");
    } else {
      toastStore.replaceAll(
        "Error: no response received from server.",
        "error",
      );
    }
    return "error";
  } else {
    if (silent) {
      console.error("Error: could not submit form.");
    } else {
      toastStore.replaceAll("Error: could not submit form.", "error");
    }
    return "error";
  }
}
