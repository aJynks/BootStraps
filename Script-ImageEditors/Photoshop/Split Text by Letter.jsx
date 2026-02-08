// enable double clicking from the Macintosh Finder or the Windows Explorer
#target photoshop

// in case we double clicked the file
app.bringToFront();

// debug level: 0-2 (0:disable, 1:break on error, 2:break at beginning)
// $.level = 0;
// debugger; // launch debugger on next line

var strtRulerUnits = app.preferences.rulerUnits;
var strtTypeUnits = app.preferences.typeUnits;

app.preferences.rulerUnits = Units.PIXELS;
app.preferences.typeUnits = TypeUnits.POINTS;

var thisDocument = app.activeDocument;

// USE THIS LINE TO GRAB TEXT FROM EXISTING LAYER
var theOriginalTextLayer = thisDocument.artLayers.getByName("NAME-OF-LAYER");
var theTextToSplit = theOriginalTextLayer.textItem.contents;

// OR USE THIS LINE TO DEFINE YOUR OWN
// var theTextToSplit = "Hello";

// suppress all dialogs
app.displayDialogs = DialogModes.NO;

//  the color of the text as a numerical rgb value
var textColor = new SolidColor;
textColor.rgb.red = 0;
textColor.rgb.green = 0;
textColor.rgb.blue = 0;

var fontSize = 120;         // font size in points
var textBaseline = 480;     // the vertical distance in pixels between the top-left corner of the document and the bottom-left corner of the text-box

for(a=0; a<theTextToSplit.length; a++){ 
// this loop will go through each character

    var newTextLayer = thisDocument.artLayers.add();        // create new photoshop layer
        newTextLayer.kind = LayerKind.TEXT;             // set the layer kind to be text
    //  newTextLayer.name = textInLayer.charAt(a);

    var theTextBox = newTextLayer.textItem;             // edit the text
        theTextBox.font = "Arial";                      // set font
        theTextBox.contents = theTextToSplit.charAt(a); // Put each character in the text
        theTextBox.size = fontSize;                           // set font size
    var textPosition = a*(fontSize*0.7);

        theTextBox.position = Array(textPosition, textBaseline);                // apply the bottom-left corner position for each character
        theTextBox.color = textColor;

};

/* Reset */

app.preferences.rulerUnits = strtRulerUnits;
app.preferences.typeUnits = strtTypeUnits;
docRef = null;
textColor = null;
newTextLayer = null;