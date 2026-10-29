// Open the ConFriKa Sign side panel when the toolbar icon is clicked, so it sits
// beside the video-call tab (Meet, Zoom web, etc.).
chrome.runtime.onInstalled.addListener(() => {
  chrome.sidePanel
    .setPanelBehavior({ openPanelOnActionClick: true })
    .catch((e) => console.warn('sidePanel behavior:', e));
});
