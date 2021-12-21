//
//  main.m
//  AudioConverter
//
//  Created by Xiao Quan on 12/21/21.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define kFileLocation CFSTR("/Users/xiaoquan/Downloads/jigsaw.mp3")

// MARK: - User Data Struct
typedef struct AudioConverterSettings {
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    
    AudioFileID              inputFile;
    AudioFileID              outputFile;
    
    UInt64                          inputFilePacketIndex;
    UInt64                          inputFilePacketCount;
    UInt32                          inputFilePacketMaxSize;
    AudioStreamPacketDescription    *inputFilePacketDescriptions;
    
    void *sourceBuffer;
    
} AudioConverterSettings;

// MARK: - Utils
static void CheckError(OSStatus error, const char *operation) {
    if (error == noErr) return;
    
    char errorString[20];
    // Is error a four char code?
    *(UInt32 *) (errorString + 1) = CFSwapInt32BigToHost(error);
    if (isprint(errorString[1]) &&
        isprint(errorString[2]) &&
        isprint(errorString[3]) &&
        isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else {
        // Format error as an integer
        sprintf(errorString, "%d", (int) error);
    }
    fprintf(stderr, "Error: %s (%s) \n", operation, errorString);
    
    exit(1);
}

// MARK: - Converter Callback
OSStatus AudioConverterCallback(AudioConverterRef inAudioConverter,
                                UInt32 *ioDataPacketCount,
                                AudioBufferList *ioData,
                                AudioStreamPacketDescription **outDataPacketDescription,
                                void *inUserData) {
    AudioConverterSettings *settings = (AudioConverterSettings *) inUserData;
    
    ioData->mBuffers[0].mData = NULL;
    ioData->mBuffers[0].mDataByteSize = 0;
    
    /* If there are not enough packets to put into ioData,
     we update the size of ioData to what's left in the file */
    if (settings->inputFilePacketIndex + *ioDataPacketCount > settings->inputFilePacketCount) {
        *ioDataPacketCount = settings->inputFilePacketCount -
                             settings->inputFilePacketIndex;
    }
    
    if (*ioDataPacketCount == 0) {
        return noErr;
    }
    
    // Alocate a buffer to be filled and converted in AudioConverterFillComplexBuffer
    if (settings->sourceBuffer != NULL) {
        free(settings->sourceBuffer);
        settings->sourceBuffer = NULL;
    }
    
    settings->sourceBuffer = (void *) calloc(1, *ioDataPacketCount * settings->inputFilePacketMaxSize);
    
    // Start reading packets into conversion (source) buffer
    UInt32 outByteCount = 0;
    OSStatus result = AudioFileReadPackets(settings->inputFile,
                                           true,
                                           &outByteCount,
                                           settings->inputFilePacketDescriptions,
                                           settings->inputFilePacketIndex,
                                           ioDataPacketCount,
                                           settings->sourceBuffer);

//    if (result == eofErr && *ioDataPacketCount) result = noErr;
//    else if (result == noErr) {
//        return result;
//    }
    // it's not an error if we just read the remainder of the file
//#ifdef MAC_OS_X_VERSION_10_7
    if (result == kAudioFileEndOfFileError && *ioDataPacketCount) result = noErr;
//#else
//    if (result == eofErr && *ioDataPacketCount) result = noErr;
//#endif
    else if (result != noErr) return result;
    
    // update source file position and AudioBuffer with read result
    settings->inputFilePacketIndex += *ioDataPacketCount;
    
    ioData->mBuffers[0].mData = settings->sourceBuffer;
    ioData->mBuffers[0].mDataByteSize = outByteCount;
    if (outDataPacketDescription) {
        *outDataPacketDescription = settings->inputFilePacketDescriptions;
    }
    
    return result;
}

void Convert(AudioConverterSettings *settings) {
    // Audio converter is created in this function
    AudioConverterRef converter;
    CheckError(AudioConverterNew(&settings->inputFormat,
                                 &settings->outputFormat,
                                 &converter),
               "Failed to create audio converter");
    
    // Calculate size of buffers and packet counts per buffer
    UInt32 packetsPerBuffer = 0;
    UInt32 outputBufferSize = 32 * 1024; // 32kB
    UInt32 sizePerPacket = settings->inputFormat.mBytesPerPacket;
    
    // Variable Bit Rate, need to use AudioConverter to get max packet size...
    if (sizePerPacket == 0) {
        UInt32 size = sizeof(sizePerPacket);
        CheckError(AudioConverterGetProperty(converter,
                                             kAudioConverterPropertyMaximumOutputPacketSize,
                                             &size,
                                             &sizePerPacket),
                   "AudioConverterGetProperty failed to get max packet size");
        
        if (sizePerPacket > outputBufferSize) {
            outputBufferSize = sizePerPacket;
        }
        
        packetsPerBuffer = outputBufferSize / sizePerPacket;
        settings->inputFilePacketDescriptions =
        (AudioStreamPacketDescription *) malloc(sizeof(AudioStreamPacketDescription) * packetsPerBuffer);
    } else {
        packetsPerBuffer = outputBufferSize / sizePerPacket;
    }
    
    // Allocate memory for conversion buffer,
    /* UInt8 is unsigned char */
    UInt8 *outputBuffer = (UInt8 *) malloc(sizeof(UInt8) * outputBufferSize);
    
    // Convert and write data
    UInt32 outputFilePacketPosition = 0; // Keeps track of where we are memory-wise in the output file.
    while(1) {
        /* AudioConverterFillComplexBuffer requires an AudioBufferList
         to put converted data into. */
        AudioBufferList convertedData;
        convertedData.mNumberBuffers = 1;
        convertedData.mBuffers[0].mNumberChannels = settings->inputFormat.mChannelsPerFrame;
        convertedData.mBuffers[0].mDataByteSize = outputBufferSize;
        convertedData.mBuffers[0].mData = outputBuffer;
        
        UInt32 ioOutputDataPackets = packetsPerBuffer;
        OSStatus error = AudioConverterFillComplexBuffer(converter,
                                                         AudioConverterCallback,
                                                         settings,
                                                         &ioOutputDataPackets,
                                                         &convertedData,
                                                         (settings->inputFilePacketDescriptions ?
                                                          settings->inputFilePacketDescriptions : nil));
        if (error || !ioOutputDataPackets) {
            break;
        }
        
        // Write Converted Data to output file
        CheckError(AudioFileWritePackets(settings->outputFile,
                                         FALSE,               // Don't we need byte counts?
                                         ioOutputDataPackets, // * settings->outputFormat.mBytesPerPacket,
                                         NULL,
                                         outputFilePacketPosition /
                                         settings->outputFormat.mBytesPerPacket,
                                         &ioOutputDataPackets,
                                         convertedData.mBuffers[0].mData),
                   "AudioFileWritePackets failed");
        outputFilePacketPosition += (ioOutputDataPackets * settings->outputFormat.mBytesPerPacket);
    }
    AudioConverterDispose(converter);
    free (outputBuffer);

}

// MARK: - Main Function
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        AudioConverterSettings audioConverterSettings = {0};
        
        CFURLRef inputFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                         kFileLocation,
                                                         kCFURLPOSIXPathStyle,
                                                         false);
        
        // Open Input File
        CheckError(AudioFileOpenURL(inputFileURL,
                         kAudioFileReadPermission,
                         0,
                         &audioConverterSettings.inputFile),
                   "AudioFileOpenURL: failed");
        
        CFRelease(inputFileURL);
        
        // Get Input Format
        UInt32 propSize = sizeof(audioConverterSettings.inputFormat);
        
        CheckError(AudioFileGetProperty(audioConverterSettings.inputFile,
                                        kAudioFilePropertyDataFormat,
                                        &propSize,
                                        &audioConverterSettings.inputFormat),
                   "AudioFileGetProperty failed to obtain asbd from input file");
        
        // Get total number of packets in file
        propSize = sizeof(audioConverterSettings.inputFilePacketCount);
        CheckError(AudioFileGetProperty(audioConverterSettings.inputFile,
                                        kAudioFilePropertyAudioDataPacketCount,
                                        &propSize,
                                        &audioConverterSettings.inputFilePacketCount),
                   "AudioFileGetProperty failed to get max packet size from input audio file");
        
        // Get the size of the largest possible packet
        propSize = sizeof(audioConverterSettings.inputFilePacketMaxSize);
        CheckError(AudioFileGetProperty(audioConverterSettings.inputFile,
                                        kAudioFilePropertyMaximumPacketSize,
                                        &propSize,
                                        &audioConverterSettings.inputFilePacketMaxSize),
                   "AudioFileGetProperty failed to get max packet size from input file");
        
        // Set up Output File
        // Defining Output File ASBD
        audioConverterSettings.outputFormat.mSampleRate = 44100.0;
        audioConverterSettings.outputFormat.mFormatID = kAudioFormatLinearPCM;
        audioConverterSettings.outputFormat.mFormatFlags = kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        audioConverterSettings.outputFormat.mBytesPerPacket = 4;
        audioConverterSettings.outputFormat.mFramesPerPacket = 1;
        audioConverterSettings.outputFormat.mBytesPerFrame = 4;
        audioConverterSettings.outputFormat.mChannelsPerFrame = 2;
        audioConverterSettings.outputFormat.mBitsPerChannel = 16;
        
        CFURLRef outputFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                               CFSTR("output.aiff"),
                                                               kCFURLPOSIXPathStyle,
                                                               false);
        
        CheckError(AudioFileCreateWithURL(outputFileURL,
                                          kAudioFileAIFFType,
                                          &audioConverterSettings.outputFormat,
                                          kAudioFileFlags_EraseFile,
                                          &audioConverterSettings.outputFile),
                   "Failed Creating output file");
        
        CFRelease(outputFileURL);
        
        // Perform Conversion
        fprintf(stdout, "Converting...\n");
        Convert(&audioConverterSettings);
        
    cleanup:
        AudioFileClose(audioConverterSettings.inputFile);
        AudioFileClose(audioConverterSettings.outputFile);
        printf("Done\r");
    }
    return 0;
}
