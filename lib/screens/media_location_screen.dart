import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async'; // Import for Timer class
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart'; // For MethodChannel
import 'package:intl/intl.dart'; // For date formatting
import 'package:native_exif/native_exif.dart'; // For EXIF data
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:video_player/video_player.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:photo_manager/photo_manager.dart';
import 'gallery_screen.dart'; // Import the GalleryScreen class
import '../model/photo_model.dart';
import '../main.dart';
import '../objectbox.g.dart';

class MediaLocationScreen extends StatefulWidget {
  final String mediaPath;
  final bool isVideo;
  final Store store; // Add the store parameter

  const MediaLocationScreen(
      {super.key,
      required this.mediaPath,
      required this.isVideo,
      required this.store});

  @override
  MediaLocationScreenState createState() => MediaLocationScreenState();
}

class MediaLocationScreenState extends State<MediaLocationScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Position? _currentPosition;
  String? _address;
  final Logger log = Logger('MediaLocationScreen');
  String?
      _updatedMediaPath; // Variable to store the updated media (image/video) path
  bool _isLoading = true; // Variable to manage the initial loading spinner
  bool _isProcessingVideo =
      false; // Variable to manage video processing spinner
  bool _isProcessingImage =
      false; // Variable to manage image processing spinner
  bool _openedSettings = false; // Flag to check if user went to settings

  VideoPlayerController? _videoController;
  bool _isMuted = false; // Variable to track mute state
  bool _showControls =
      true; // Variable to manage visibility of play/pause button
  Timer? _hideControlsTimer; // Timer to hide controls after 2 seconds

  // Variables for the Progress Bar
  double _videoProcessingProgress = 0.0;
  Timer? _videoProgressTimer;
  Duration _videoDuration = Duration.zero;
  Duration _videoTotalDuration = Duration.zero;

  // Controller for text animation
  late AnimationController _textAnimationController;
  late Animation<double> _textOpacityAnimation;

  Directory? _tempDir;
  String? _fontFilePath;
  AssetEntity? _lastAsset; // Variable to store the last media asset
  AssetEntity? _lastCapturedAsset; // Variable to store the last captured media
  bool _isLandscape = false; // Add this variable if not already present
  bool _isLandscapeRight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addObserver(this); // Add observer to track app lifecycle changes
    _initializeFonts(); // Method to initialize fonts
    _listFFmpegFilters(); // Method to list the filters available
    _requestPermission(); // Request permissions when starting
    _getCurrentLocation(); // Get current location

    // Initialize the animation controller for the text
    _textAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _textOpacityAnimation =
        Tween<double>(begin: 0.5, end: 1.0).animate(_textAnimationController);

    // Agregar listener para la orientación
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    // Detectar orientación inicial
    _checkOrientation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance
        .removeObserver(this); // Remove observer when widget is disposed
    _videoController?.removeListener(_videoListener);
    _videoController?.dispose();
    _hideControlsTimer?.cancel();
    _videoProgressTimer?.cancel();
    _textAnimationController.dispose();
    super.dispose();
  }

  // Detect app lifecycle state changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _openedSettings) {
      // Only check permissions if we came back from the settings screen
      _checkPermissionStatus();
      _openedSettings = false; // Reset the flag once we've checked
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _checkOrientation();
  }

  void _checkOrientation() {
    final windowPadding = WidgetsBinding.instance.window.viewPadding;
    final isLandscape = windowPadding.left > 0;
    setState(() {
      _isLandscapeRight = isLandscape;
    });
  }

  Future<void> _checkPermissionStatus() async {
    var result = await PhotoManager.requestPermissionExtend();
    if (result == PermissionState.authorized ||
        result == PermissionState.limited) {
      // Permission granted, proceed with loading the gallery
      _loadGalleryAssets();
    } else {
      // Permission still denied, show the permission dialog again if necessary
      log.severe("Permission denied even after returning from settings");
    }
  }

  Future<void> _requestPermission() async {
    var result = await PhotoManager.requestPermissionExtend();
    if (result == PermissionState.authorized ||
        result == PermissionState.limited) {
      // Permission granted or limited access, continue
      _loadGalleryAssets(); // Load photos and videos of the gallery
    } else if (result == PermissionState.denied) {
      // Permission is denied, show a dialog to guide user to settings
      _showPermissionDeniedDialog();
    } else {
      log.severe("Permission denied to access the gallery");
    }
  }

  Future<void> _loadGalleryAssets() async {
    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.all, // To get both photos and videos
    );

    // Specify page and size explicitly
    final List<AssetEntity> mediaFiles =
        await albums[0].getAssetListPaged(page: 0, size: 100);

    // Get the last media file
    if (mediaFiles.isNotEmpty) {
      _lastAsset = mediaFiles.first;
    }

    setState(() {
      // TODO: Update state to show the files in the UI
      // Example: _mediaFiles = mediaFiles;
    });
  }

  Future<void> _savePhotoToDatabase() async {
    if (!widget.isVideo) {
      final box = widget.store.box<Photo>();

      // After saving to gallery, retrieve the latest asset by creation date
      List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
      );

      if (albums.isNotEmpty) {
        List<AssetEntity> recentAssets = await albums[0].getAssetListRange(
          start: 0,
          end: 1,
        );

        if (recentAssets.isNotEmpty) {
          final asset =
              recentAssets.first; // Assume this is the latest captured photo

          // Check if the galleryId already exists in the box to avoid duplicates
          final existingPhotos = box.getAll();
          final exists =
              existingPhotos.any((photo) => photo.galleryId == asset.id);

          if (!exists) {
            final photo = Photo(
              galleryId: asset.id, // Store gallery ID
              captureDate: DateTime.now(),
            );
            box.put(photo); // Save photo info in ObjectBox

            // Update the ValueNotifier with the new list of photos
            photoNotifier.value =
                box.getAll(); // This notifies the photoNotifier listeners
          }
        }
      }
    }
  }

  void _showGallery() async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            GalleryScreen(store: widget.store, cameras: cameras),
      ),
    );

    if (deleted == true) {
      final fileExists = await File(widget.mediaPath).exists();
      if (!fileExists) {
        Navigator.of(context).pop(true); // Return to CameraScreen
      } else {
        Navigator.of(context).pop(true); // Return to CameraScreen
        // setState(() {
        //   // Continue showing current media
        // });
      }
    }
  }

  Future<void> _initializeFonts() async {
    try {
      // Load the TTF font directly from the Assets
      final fontData =
          await rootBundle.load('assets/fonts/roboto/Roboto-Bold.ttf');
      final fontBytes = fontData.buffer.asUint8List();

      // Write the font to a temporary file so that FFmpeg can access it
      _tempDir = await getTemporaryDirectory();
      final fontFile = File('${_tempDir!.path}/Roboto-Bold.ttf');
      await fontFile.writeAsBytes(fontBytes);

      // Verify that the font file exists
      if (!await fontFile.exists()) {
        log.severe(
            'The font file could not be written to the temporary directory.');
        return;
      }

      _fontFilePath = fontFile.path;

      // Register the font directories
      if (Platform.isAndroid) {
        await FFmpegKitConfig.setFontDirectoryList([
          '/system/fonts', // System Fonts Directory
          _tempDir!.path, // Temporary Directory where the font is
        ]);
      } else if (Platform.isIOS) {
        await FFmpegKitConfig.setFontDirectoryList(
            [_tempDir!.path], // Temporary Directory where the font is
            {} // Empty map for mapping to avoid NSNull issue
            );
      }
    } catch (e) {
      log.severe('Error initializing fonts: $e');
    }
  }

  Future<void> _listFFmpegFilters() async {
    final session = await FFmpegKit.execute('-filters');
    final output = await session.getAllLogsAsString();
    // Check if drawtext filter is available
    final bool drawTextFilter = output?.contains('drawtext') ?? false;
    if (!drawTextFilter) {
      log.severe('drawtext filter is not available in FFmpeg');
    }
    log.info('FFmpeg filters:\n$output');
  }

  // Function to obtain the current location
  Future<void> _getCurrentLocation() async {
    setState(() {
      _isLoading = true; // Show initial loading spinner
    });

    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      log.severe('Location services are disabled.');
      setState(() {
        _isLoading = false;
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        log.severe('Location permissions are denied');
        setState(() {
          _isLoading = false;
        });
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      log.severe('Location permissions are permanently denied');
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      _currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      );
      log.info('Current position: $_currentPosition');

      if (_currentPosition != null) {
        // Obtain address from coordinates
        await _getAddressFromCoordinates(
            _currentPosition!.latitude, _currentPosition!.longitude);
      }

      // Update state to hide initial loading spinner
      setState(() {
        _isLoading = false;
      });

      // Start processing video or image in a separate thread
      if (widget.isVideo) {
        // Get the video duration
        await _getVideoDuration(widget.mediaPath);

        setState(() {
          _isProcessingVideo = true; // Show video processing spinner
        });

        // Start the timer for the progress bar
        _startVideoProgressTimer();

        // Run the video processing in a separate Future
        Future(() async {
          await _writeTextOnVideoAndSaveToGallery(widget.mediaPath);
          setState(() {
            _isProcessingVideo = false; // Hide video processing spinner
          });

          // Detener el Timer y asegurar que la barra de progreso llegue al 100%
          _videoProgressTimer?.cancel();
          setState(() {
            _videoProcessingProgress = 1.0;
          });
        });
      } else {
        // If it's an image, process it directly with spinner
        setState(() {
          _isProcessingImage = true; // Show image processing spinner
        });

        Future(() async {
          await _writeTextOnImageAndSaveToGallery(widget.mediaPath);
          setState(() {
            _isProcessingImage = false; // Hide image processing spinner
          });
        });
      }
    } catch (e) {
      log.severe('Failed to obtain location or process media: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Function to get the duration of the video
  Future<void> _getVideoDuration(String videoPath) async {
    final tempController = VideoPlayerController.file(File(videoPath));
    await tempController.initialize();
    _videoDuration = tempController.value.duration;
    tempController.dispose();

    // Calculate the estimated total duration (video duration + 40%)
    _videoTotalDuration = _videoDuration * 1.4;
  }

  // Function to start the timer for the progress bar
  void _startVideoProgressTimer() {
    _videoProcessingProgress = 0.0;
    const tickDuration = Duration(milliseconds: 500); // Update every 500ms
    final totalTicks =
        (_videoTotalDuration.inMilliseconds / tickDuration.inMilliseconds)
            .ceil();

    int tick = 0;

    _videoProgressTimer = Timer.periodic(tickDuration, (timer) {
      tick++;
      setState(() {
        _videoProcessingProgress =
            (tick / totalTicks).clamp(0.0, 1.0).toDouble();
      });

      if (_videoProcessingProgress >= 1.0) {
        timer.cancel();
      }
    });
  }

  // Function to get the address from the coordinates
  Future<void> _getAddressFromCoordinates(double lat, double lon) async {
    final accessToken = dotenv.env['MAPBOX_ACCESS_TOKEN'];

    final url =
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$lon,$lat.json?access_token=$accessToken';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['features'].isNotEmpty) {
          setState(() {
            // Adjust the address to be split into three lines
            final addressParts = data['features'][0]['place_name'].split(',');
            _address =
                "${addressParts[0].trim()}\n${addressParts[1].trim()}\n${addressParts[2].trim()}";
          });
          log.info('Address: $_address');
        }
      } else {
        log.severe('Failed to get address from coordinates');
      }
    } catch (e) {
      log.severe('Error fetching address: $e');
    }
  }

  // Function to convert decimal coordinates to DMS format
  String _convertToDMS(double decimal) {
    final degrees = decimal.truncate();
    final minutes = ((decimal - degrees) * 60).truncate();
    final seconds = (((decimal - degrees) * 60) - minutes) * 60;

    return '${degrees.abs()}°${minutes.abs()}\'${seconds.abs().toStringAsFixed(2)}" ${decimal >= 0 ? 'N' : 'S'}';
  }

  // TODO: To add ICC Profile data (e.g., RedMatrixColumn, GreenMatrixColumn, BlueMatrixColumn, MediaWhitePoint),
  // consider integrating an image processing library that supports full ICC profile handling, such as
  // ImageMagick or GraphicsMagick. You may need to extract the ICC profile from the image file, modify it,
  // and then re-embed it using a tool that provides robust support for ICC profiles.
  // This step would involve:
  // 1. Extracting the existing ICC profile from the image if present.
  // 2. Modifying or appending the necessary color profile metadata.
  //    - Profile Description
  //    - Red Matrix Column
  //    - Green Matrix Column
  //    - Blue Matrix Column
  //    - Media White Point
  //    - Red Tone Reproduction Curve
  //    - Green Tone Reproduction Curve
  //    - Blue Tone Reproduction Curve
  // 3. Re-embedding the updated ICC profile back into the image.
  // Note: Flutter does not natively support ICC profile editing, and this may need an external tool or plugin
  // to be implemented efficiently for both Android and iOS.
  // IMPORTANT: ICC Profile data is not essential to verify the integrity of the image, but it can be useful for color management.

  // Function to add EXIF data to the image
  Future<void> _addExifData(String imagePath) async {
    try {
      final exif = await Exif.fromPath(imagePath);

      if (_currentPosition != null) {
        // Add GPS coordinates
        await exif.writeAttributes({
          'GPSLatitude': _currentPosition!.latitude.toString(),
          'GPSLongitude': _currentPosition!.longitude.toString(),
        });
      }

      // Add GPS Date/Time in UTC
      final now = DateTime.now().toUtc();
      await exif.writeAttributes({
        'GPSDateStamp': DateFormat('yyyy:MM:dd').format(now),
        'GPSTimeStamp': DateFormat('HH:mm:ss').format(now),
      });

      // Add other EXIF data with ASCII encoding
      await exif.writeAttributes({
        'DateTimeOriginal':
            DateFormat('yyyy:MM:dd HH:mm:ss').format(DateTime.now()),
        'UserComment':
            'Desarrollado por T3 AI SAT. Direccion donde se toma la foto: ${_address?.replaceAll('\n', ' ') ?? 'Sin direccion'}',
        'ProfileDescription': 'sRGB', // Add color profile description
        'ColorSpace': '1', // Add color space as sRGB (value 1 means sRGB)
      });

      await exif.close();
    } catch (e) {
      log.severe('Error writing EXIF data: $e');
    }
  }

  int countLinesInText(String text) {
    // Verify if the last two characters are '\n'
    if (text.length >= 2 && text.substring(text.length - 2) == '\n\n') {
      // Eliminate the last two characters
      text = text.substring(0, text.length - 2);
    }

    // Obtain the correct number of lines with text
    int numberOfLines = text.split('\n').length;

    return numberOfLines;
  }

  // Function to get the directory path for saving on Android in the DCIM/Camera folder
  Future<String> _getExternalStoragePath() async {
    // Android DCIM directory
    Directory? externalDir = Directory('/storage/emulated/0/DCIM/Camera');
    if (await externalDir.exists()) {
      return externalDir.path;
    } else {
      // If the directory doesn't exist, create it
      await externalDir.create(recursive: true);
      return externalDir.path;
    }
  }

  // Function to save the photo with the location on the device and the gallery
  Future<void> _writeTextOnImageAndSaveToGallery(String imagePath) async {
    if (_currentPosition == null) {
      log.severe('Location data not available');
      return;
    }

    try {
      // Read the original image file as bytes
      final bytes = await File(imagePath).readAsBytes();
      final img.Image originalImage = img.decodeImage(bytes)!;

      // Load the font from the assets to draw text on the image
      final fontData = await rootBundle.load(
          'assets/fonts/roboto_bold/Roboto-Bold-20-size-white-color.ttf.zip');
      final font = img.BitmapFont.fromZip(fontData.buffer.asUint8List());

      // Convert coordinates to Degrees, Minutes, Seconds (DMS) format
      final latitudeDMS = _convertToDMS(_currentPosition!.latitude);
      final longitudeDMS = _convertToDMS(_currentPosition!.longitude);

      // Get the current date and time
      final now = DateTime.now();
      final timeZoneName =
          now.timeZoneName; // Detects the time zone name (e.g., CEST, CET)

      final formattedLocalTime =
          '${DateFormat('dd MMM yyyy HH:mm:ss').format(now)} $timeZoneName';

      final formattedLocation = 'Lat: $latitudeDMS\nLon: $longitudeDMS';
      log.info('Formatted location: $formattedLocation');

      // Format the address and location for displaying on the image
      final formattedAddress = _address?.split(',').join('\n');

      // Build the text that will be drawn on the image
      final formattedText = '''$formattedLocalTime
$latitudeDMS $longitudeDMS
$formattedAddress
T3 AI SAT Copr.''';

      // Calculate text size
      final numLineBreaks = countLinesInText(formattedText);

      final textHeight = font.lineHeight * numLineBreaks;

      // Draw the address and coordinates on the image
      final updatedImage = img.drawString(
        originalImage,
        formattedText,
        font: font,
        x: 20, // Left margin
        y: originalImage.height -
            textHeight -
            20, // Position the text at the bottom
        color: img.ColorRgba8(255, 255, 255, 255), // White color for text
      );

      // Generate the filename with the format t3aisat_yyyymmdd_hhmmss.jpg
      final formattedDate = DateFormat('yyyyMMdd_HHmmss').format(now);

      String updatedImagePath;

      if (Platform.isAndroid) {
        // Use custom path for Android DCIM/Camera folder
        final externalStoragePath = await _getExternalStoragePath();
        updatedImagePath = path.join(
          externalStoragePath,
          't3aisat_$formattedDate.jpg', // Filename with the desired format
        );
      } else if (Platform.isIOS) {
        // Use application documents directory for initial save on iOS
        final directory = await getApplicationDocumentsDirectory();
        updatedImagePath = path.join(
          directory.path,
          't3aisat_$formattedDate.jpg', // Filename with the desired format
        );
      } else {
        log.severe('Unsupported platform');
        return;
      }

      // Save the modified image to the specified path
      final updatedImageFile = File(updatedImagePath);
      log.info('Updated image path: $updatedImagePath');
      log.info('Updated image file path: ${updatedImageFile.path}');

      // Write the updated image bytes to the file
      await updatedImageFile.writeAsBytes(img.encodeJpg(updatedImage));

      // Verify if the file exists after saving
      if (await updatedImageFile.exists()) {
        log.info('File created successfully: ${updatedImageFile.path}');
      } else {
        log.severe('File not created: ${updatedImageFile.path}');
        return;
      }

      // Add EXIF data (e.g., GPS coordinates, description) to the image
      await _addExifData(updatedImageFile.path);

      // Request permission to save in the gallery
      var status = await Permission.photos.status;
      if (!status.isGranted) {
        status = await Permission.photos.request();
      }

      if (status.isGranted) {
        if (Platform.isAndroid) {
          // Save to gallery using ImageGallerySaver for Android
          if (await updatedImageFile.exists()) {
            final result = await SaverGallery.saveFile(
              filePath: updatedImageFile.path,
              fileName: 't3aisat_$formattedDate.jpg',
              androidRelativePath: 'Pictures/t3aisat',
              skipIfExists: false,
            );
            log.info('Image saved to gallery: $result');
          }
        } else if (Platform.isIOS) {
          // For iOS, save to gallery and then update ObjectBox
          // Use platform channel to save the image with EXIF metadata on iOS
          await _saveImageToGalleryWithExifIOS(updatedImagePath);
          // Update ObjectBox with the new gallery ID
          await _savePhotoToDatabase();
          log.info('Updated image saved to gallery on iOS');
        }
      } else {
        log.severe('Permission denied to access photos');
      }

      // Call _onCaptureCompleted after saving the image
      await _onCaptureCompleted(updatedImagePath);

      // Update the state to reflect the new image path in the UI
      setState(() {
        _updatedMediaPath = updatedImagePath;
        // _isLoading is already false; no need to set here
      });
    } catch (e) {
      // Log any errors that occur during the image processing
      log.severe('Failed to process image: $e');
      setState(() {
        _isLoading = false;
        _isProcessingImage = false;
      });
    }
  }

  // Function to save the image to the gallery with EXIF metadata on iOS
  Future<void> _saveImageToGalleryWithExifIOS(String imagePath) async {
    try {
      if (imagePath.isEmpty) {
        log.severe('Invalid image path provided.');
        return;
      }
      // Create a method channel to interact with native iOS code
      const platform = MethodChannel('com.t3aisat/save_to_gallery');
      await platform
          .invokeMethod('saveImageWithExif', {'imagePath': imagePath});
      log.info('Updated image saved to gallery on iOS');
    } catch (e) {
      log.severe(
          'Failed to save image to gallery on iOS with EXIF metadata: $e');
    }
  }

  // Function to write text on the video and save it in the gallery
  Future<void> _writeTextOnVideoAndSaveToGallery(String videoPath) async {
    if (_currentPosition == null || _fontFilePath == null) {
      log.severe('Location data or font path not available');
      return;
    }

    try {
      // Verify that the font file path is set
      if (_fontFilePath == null) {
        log.severe('Font file path is not initialized.');
        return;
      }

      // Verify that the input video exists
      final inputVideoFile = File(videoPath);
      if (!await inputVideoFile.exists()) {
        log.severe('Input video file does not exist at path: $videoPath');
        return;
      }

      // Convert the .temp file to .mp4 by copying it
      final String inputMp4Path = path.join(
        path.dirname(videoPath),
        '${path.basenameWithoutExtension(videoPath)}.mp4',
      );
      final inputMp4File = File(inputMp4Path);
      await inputVideoFile.copy(inputMp4Path);

      // Verify that the input video exists
      if (!await inputMp4File.exists()) {
        log.severe('Converted MP4 file does not exist at path: $inputMp4Path');
        return;
      }

      // Optionally, delete the original .temp file if no longer needed
      // await inputVideoFile.delete();

      // Verify that the file has a .mp4 extension
      if (path.extension(inputMp4Path).toLowerCase() != '.mp4') {
        log.severe('Input video file is not an MP4: $inputMp4Path');
        return;
      }

      // Convert coordinates to DMS (degrees, minutes, seconds) format
      final latitudeDMS = _convertToDMS(_currentPosition!.latitude);
      final longitudeDMS = _convertToDMS(_currentPosition!.longitude);

      // Get the current date and time
      final now = DateTime.now();
      final timeZoneName =
          now.timeZoneName; // Detects the time zone name (e.g., CEST, CET)

      final formattedLocalTime =
          '${DateFormat('dd MMM yyyy HH:mm:ss').format(now)} $timeZoneName';

      final formattedLocation = 'Lat: $latitudeDMS\nLon: $longitudeDMS';
      final descriptionLocationDMS = formattedLocation
          .replaceAll('"', r'˝') // Escape double quotes
          .replaceAll(':', r'.') // Escape colons
          .replaceAll('\n', ' '); // Replace new lines with spaces
      log.info('Formatted location: $descriptionLocationDMS');

      // Format the address and location for displaying on the video
      String formattedAddress = _address ?? 'Sin direccion';

      // Escape special characters
      formattedAddress = formattedAddress
          .replaceAll('"', r'˝') // Escape double quotes
          .replaceAll(':', r'\:') // Escape colons
          .replaceAll('%', r'\%'); // Escape percent signs

      // Flatten formattedAddress to be a single line and escape special characters
      final String escapedAddress = formattedAddress.replaceAll(
          '\n', ' '); // Replace new lines with spaces

      // Build the text that will be drawn on the video
      final appName = 'T3 AI SAT';
      final formattedText = '''$formattedLocalTime
$latitudeDMS $longitudeDMS
$formattedAddress
$appName ©''';

      // Escape special characters for FFmpeg command
      String escapedText = formattedText
          .replaceAll('"', r'˝') // Escape double quotes
          .replaceAll(':', r'\:') // Escape colons
          .replaceAll('%', r'\%'); // Escape percent signs

      // Log the formatted and escaped text for debugging
      log.info('Formatted text:\n$formattedText');
      log.info('Escaped text:\n$escapedText');

      // Configure the output path
      if (_tempDir == null) {
        log.severe('Temporary directory is not initialized.');
        return;
      }
      final Directory extDir = _tempDir!;
      final String dirPath = '${extDir.path}/Videos/flutter_test';
      await Directory(dirPath).create(recursive: true);
      final String outputPath = path.join(
        dirPath,
        't3aisat_${DateFormat('yyyyMMdd_HHmmss').format(now)}.mp4',
      );

      // Log the paths for debugging
      log.info('Font file path: $_fontFilePath');
      log.info('Input video path: $inputMp4Path');
      log.info('Output video path: $outputPath');

      // Build FFmpeg command
      final String ffmpegCommand =
          "drawtext=fontfile='$_fontFilePath':text='$escapedText':fontcolor=white:fontsize=20:line_spacing=2:x=10:y=H-th-10";

      final command = [
        '-y',
        '-i',
        inputMp4Path,
        '-vf',
        ffmpegCommand,
        '-codec:a',
        'copy',
        '-metadata',
        'description="$descriptionLocationDMS"', // Escaped metadata for coordinates
        '-metadata',
        'comment="$escapedAddress $appName"', // Escaped metadata for address
        outputPath,
      ];

      log.info('FFmpeg command: ffmpeg ${command.join(' ')}');

      // Execute FFmpeg command
      final session = await FFmpegKit.executeWithArguments(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        log.info('FFmpeg command executed successfully');
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          final result = await SaverGallery.saveFile(
            filePath: outputPath,
            fileName:
                't3aisat_${DateFormat('yyyyMMdd_HHmmss').format(now)}_data.mp4',
            androidRelativePath: 'Movies/t3aisat',
            skipIfExists: false,
          );
          log.info('Video saved to gallery: $result');

          // Call _onCaptureCompleted after saving the video
          await _onCaptureCompleted(outputPath);

          setState(() {
            _updatedMediaPath = outputPath;
            log.info('Video processed and saved at $outputPath');
          });

          // Initialize the video controller without auto-playing
          _videoController =
              VideoPlayerController.file(File(_updatedMediaPath!));
          await _videoController!.initialize();
          _videoController!.setLooping(false); // Do not loop the video
          _videoController!.addListener(_videoListener);

          // Update the state to hide the spinner
          setState(() {
            // _isProcessingVideo will be set to false in the calling Future
            _showControls = true; // Show play button initially
          });
        } else {
          log.severe('Processed video file does not exist.');
          setState(() {
            // _isProcessingVideo will be set to false in the calling Future
          });
        }
      } else {
        log.severe('Failed to process video');
        final logs = await session.getAllLogsAsString();
        log.severe('FFmpeg command failed with return code $returnCode');
        log.severe('FFmpeg logs:\n$logs');
        setState(() {
          // _isProcessingVideo will be set to false in the calling Future
        });
      }
    } catch (e) {
      log.severe('Error processing video: $e');
      setState(() {
        // _isProcessingVideo will be set to false in the calling Future
      });
    }
  }

  // Listener to handle video end
  void _videoListener() {
    if (_videoController == null) return;

    if (_videoController!.value.position >= _videoController!.value.duration &&
        !_videoController!.value.isPlaying) {
      setState(() {
        _showControls = true; // Show play button when video ends
      });
    }
  }

  // Function to toggle play and pause
  void _togglePlayPause() {
    if (_videoController == null) return;

    setState(() {
      if (_videoController!.value.isPlaying) {
        _videoController!.pause();
        _showControls = true; // Show pause button when paused
        _hideControlsTimer?.cancel();
      } else {
        _videoController!.play();
        _showControls = false; // Hide play button when playing
        _startHideControlsTimer();
      }
    });
  }

  // Function to toggle mute and unmute
  void _toggleMute() {
    if (_videoController == null) return;

    setState(() {
      _isMuted = !_isMuted;
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      _showControls = true;
      _startHideControlsTimer();
    });
  }

  // Function to start the timer to hide controls after 2 seconds
  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Acceso Galería Fotos'),
          content:
              const Text('Permite el acceso a tus fotos en Ajustes, por favor'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openedSettings = true; // Set flag before going to setting
                PhotoManager
                    .openSetting(); // Open app settings to allow user to grant permission
              },
              child: const Text('Abrir Ajustes'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    );
  }

  // Function that handles the completion of image or video capture
  Future<void> _onCaptureCompleted(String filePath) async {
    // Save the reference of the last captured file in `_lastCapturedAsset`
    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.all,
    );
    if (albums.isNotEmpty) {
      // Get the most recent assets
      final List<AssetEntity> recentAssets = await albums[0].getAssetListRange(
        start: 0,
        end: 1,
      );
      if (recentAssets.isNotEmpty) {
        setState(() {
          _lastCapturedAsset =
              recentAssets.first; // Store the most recent media
        });
      }
    }
  }

  // New helper methods for UI components
  Widget _buildGalleryButton() {
    if (_lastCapturedAsset == null) return const SizedBox.shrink();
    
    return GestureDetector(
      onTap: _showGallery,
      child: FutureBuilder<Uint8List?>(
        future: (_lastCapturedAsset ?? _lastAsset)!.thumbnailDataWithSize(
          const ThumbnailSize.square(100),
        ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
            return SizedBox(
              width: 80, // Larger in landscape
              height: 80,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: Image.memory(
                  snapshot.data!,
                  fit: BoxFit.cover,
                ),
              ),
            );
          }
          return Container(
            width: 80,
            height: 80,
            color: Colors.grey,
          );
        },
      ),
    );
  }

  Widget _buildCoordinatesSection() {
    if (_currentPosition == null) return const SizedBox.shrink();
    
    return Padding(
      padding: EdgeInsets.only(
        left: _isLandscapeRight ? 40.0 : 16.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.location_on,
            color: Color(0xFF388E3C),
            size: 30,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Latitud: ${_currentPosition!.latitude.toStringAsFixed(6)}\nLongitud: ${_currentPosition!.longitude.toStringAsFixed(6)}',
              textAlign: TextAlign.left,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 16,
                color: Color(0xFF424242),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressSection() {
    if (_address == null) return const SizedBox.shrink();
    
    return Padding(
      padding: EdgeInsets.only(
        left: _isLandscapeRight ? 40.0 : 16.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.home,
            color: Color(0xFF388E3C),
            size: 30,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _address!,
              textAlign: TextAlign.left,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 16,
                color: Color(0xFF424242),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaContent() {
    return Stack(
      children: [
        // Media display
        if (widget.isVideo)
          _updatedMediaPath != null &&
                  _videoController != null &&
                  _videoController!.value.isInitialized
              ? _buildVideoPlayer()
              : const SizedBox.shrink()
        else if (_updatedMediaPath != null)
          Image.file(
            File(_updatedMediaPath!),
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
          ),

        // Processing overlays
        if (widget.isVideo && _isProcessingVideo)
          _buildVideoProcessingOverlay(),
        if (!widget.isVideo && _isProcessingImage)
          const Center(
            child: CircularProgressIndicator(
              color: Color(0xFF1976D2),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoPlayer() {
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _showControls = true;
            _startHideControlsTimer();
          });
        },
        child: AspectRatio(
          aspectRatio: _videoController!.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_videoController!),
              if (_showControls) ...[
                Container(color: Colors.black.withOpacity(0.3)),
                _buildVideoControls(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoProcessingOverlay() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar
          SizedBox(
            width: MediaQuery.of(context).size.width * 0.8,
            child: LinearProgressIndicator(
              value: _videoProcessingProgress,
              backgroundColor: Colors.grey[300],
              color: const Color(0xFF1976D2),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 16),
          // Informative text with pulsating opacity animation
          FadeTransition(
            opacity: _textOpacityAnimation,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: MediaQuery.of(context).size.width * 0.10,
              ),
              child: const Text(
                'Escribiendo metadatos en los fotogramas del vídeo. Puedes continuar usando la aplicación mientras se completa el procesamiento.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF1976D2),
                  fontSize: 16,
                  fontFamily: 'Roboto',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoControls() {
    return Stack(
      children: [
        // Play/Pause button in center
        Center(
          child: GestureDetector(
            onTap: _togglePlayPause,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withOpacity(0.5),
              ),
              padding: const EdgeInsets.all(12),
              child: Icon(
                _videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 48,
              ),
            ),
          ),
        ),
        // Progress bar at bottom
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: VideoProgressIndicator(
            _videoController!,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: Colors.blue,
              bufferedColor: Colors.grey,
              backgroundColor: Colors.black,
            ),
          ),
        ),
        // Mute button at bottom right
        Positioned(
          bottom: 50,
          right: 20,
          child: GestureDetector(
            onTap: _toggleMute,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withOpacity(0.5),
              ),
              padding: const EdgeInsets.all(8),
              child: Icon(
                _isMuted ? Icons.volume_off : Icons.volume_up,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Obtener la orientación específica del dispositivo
    final orientation = MediaQuery.of(context).orientation;
    final deviceOrientation = MediaQuery.of(context).orientation;
    final isLandscapeRight = deviceOrientation == Orientation.landscape;
    final isLandscape = orientation == Orientation.landscape;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        return;
      },
      child: Scaffold(
        appBar: AppBar(
          iconTheme: const IconThemeData(color: Color(0xFF1976D2)),
          title: const Text(
            'GeoPosición',
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1976D2),
            ),
          ),
          backgroundColor: const Color(0xFFE6E6E6),
          elevation: 0,
        ),
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF1976D2),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  if (!isLandscape) {
                    return Column(
                      children: [
                        Expanded(child: _buildMediaContent()),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Coordenadas y dirección
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_currentPosition != null)
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(
                                            Icons.location_on,
                                            color: Color(0xFF388E3C),
                                            size: 30,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Latitud: ${_currentPosition!.latitude.toStringAsFixed(6)}\nLongitud: ${_currentPosition!.longitude.toStringAsFixed(6)}',
                                              textAlign: TextAlign.left,
                                              style: const TextStyle(
                                                fontFamily: 'Roboto',
                                                fontSize: 16,
                                                color: Color(0xFF424242),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    const SizedBox(height: 16),
                                    if (_address != null)
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(
                                            Icons.home,
                                            color: Color(0xFF388E3C),
                                            size: 30,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _address!,
                                              textAlign: TextAlign.left,
                                              style: const TextStyle(
                                                fontFamily: 'Roboto',
                                                fontSize: 16,
                                                color: Color(0xFF424242),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                              // Botón de galería
                              const SizedBox(width: 16),
                              _buildGalleryButton(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    );
                  }

                  // Diseño landscape con padding condicional
                  return Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(height: 20),
                              _buildGalleryButton(),
                              const SizedBox(height: 20),
                              _buildCoordinatesSection(),
                              const SizedBox(height: 20),
                              _buildAddressSection(),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: _isLandscapeRight ? 10.0 : 40.0,
                          ),
                          child: _buildMediaContent(),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
