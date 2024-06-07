using Flutnet.Interop;
using Foundation;
using UIKit;

namespace Flutnet.Sample
{
    [Register("AppDelegate")]
    public class AppDelegate : FlutterAppDelegate
    {
        private FlutterEngine _flutterEngine = new FlutterEngine("flutnet");

        [Export("application:didFinishLaunchingWithOptions:")]
        public override bool FinishedLaunching(UIApplication application, NSDictionary launchOptions)
        {
            _flutterEngine.Run();
            return base.FinishedLaunching(application, launchOptions);
        }
    }
}