var saveFolder = new Folder( "d:\\Projects\\_IncSave" );
var saveExt = 'png';  
var saveSufixStart = '_';  
var saveSufixLength = 3;  
// End of user options   
  
var docName = decodeURI ( activeDocument.name );  
docName = docName.match( /(.*)(\.[^\.]+)/ ) ? docName = docName.match( /(.*)(\.[^\.]+)/ ) : docName = [ docName, docName, undefined ];  
var saveName = docName[ 1 ]; // activeDocument name with out ext  
var files = saveFolder.getFiles( saveName + '*.' + saveExt );// get an array of files matching doc name prefix  
  
var saveNumber = files.length + 1;  
//alert("New file number: " + zeroPad( saveNumber, saveSufixLength ));  
var saveFile = new File( saveFolder + '/' + saveName + '_' + zeroPad( saveNumber, saveSufixLength ) + '.' + saveExt );  
saveAsPNG(saveFile, 9);  
  
function zeroPad ( num, digit ) {   
   var tmp = num.toString();   
   while (tmp.length < digit) { tmp = "0" + tmp;}   
   return tmp;  
}

function saveAsPNG(saveFile, quality) { 
    pngOpts = new PNGSaveOptions();
    pngOpts.compression = quality; //0-9
    pngOpts.interlaced = false;
    activeDocument.saveAs(File(saveFile), pngOpts, true); 
}