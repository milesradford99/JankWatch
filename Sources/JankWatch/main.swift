#if os(macOS)
JankWatchApp.main()
#else
print("JankWatch is a macOS app. On Linux only JankWatchCore and its tests are built.")
#endif
